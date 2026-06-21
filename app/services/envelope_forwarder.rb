require "uri"

# Forwards a Sentry envelope to a second Splat (or Sentry) instance.
#
# The configured Setting.forward_dsn supplies the *target host* only — scheme,
# host, port. Project identity (slug, public_key) is taken from the inbound
# request's project, so each app's events land in its own project on the
# downstream instance instead of all collapsing into the configured DSN's
# project. The downstream side needs to know about the project (pre-seeded or
# auto-created via SPLAT_AUTO_CREATE_SLUGS — see DsnAuthenticationService).
#
# Failures are logged, never raised — forwarding is best-effort and must
# never block ingest.
class EnvelopeForwarder
  class InvalidDsn < StandardError; end

  Target = Struct.new(:scheme, :host, :port) do
    def envelope_url(slug)
      port_part = port ? ":#{port}" : ""
      "#{scheme}://#{host}#{port_part}/api/#{slug}/envelope/"
    end
  end

  TIMEOUT_SECONDS = 3

  class << self
    def forward(raw_body, project:, content_type: "application/x-sentry-envelope")
      setting = Setting.instance
      return unless setting.forwarding?

      req = outbound_request(setting.forward_dsn, project)

      conn = Faraday.new(url: req[:url]) do |f|
        f.options.timeout = TIMEOUT_SECONDS
        f.options.open_timeout = TIMEOUT_SECONDS
      end

      response = conn.post do |r|
        r.headers["Content-Type"] = content_type
        r.headers["X-Sentry-Auth"] = req[:auth_header]
        r.headers["X-Splat-Forwarder-Token"] = req[:forwarder_token] if req[:forwarder_token].present?
        r.body = raw_body
      end

      unless response.success?
        Rails.logger.warn("EnvelopeForwarder: upstream returned #{response.status} for project=#{project.slug}")
      end
    rescue InvalidDsn => e
      Rails.logger.warn("EnvelopeForwarder: invalid DSN configured (#{e.message})")
    rescue Faraday::Error => e
      Rails.logger.warn("EnvelopeForwarder: forward failed: #{e.class} #{e.message}")
    end

    # Build the outbound URL, X-Sentry-Auth, and optional shared-secret token
    # for a given project. Exposed so tests can verify forwarding identity
    # without doing a real HTTP round trip.
    def outbound_request(forward_dsn, project)
      target = parse_dsn(forward_dsn)
      {
        url: target.envelope_url(project.slug),
        auth_header: auth_header(project.public_key),
        forwarder_token: ENV["SPLAT_FORWARDER_TOKEN"]
      }
    end

    # Parses the configured forward_dsn. Only scheme/host/port are used at
    # forward time — the embedded key/project_id are ignored (kept here so
    # the operator can paste a real DSN string into Settings).
    def parse_dsn(string)
      uri = URI.parse(string)
      raise InvalidDsn, "must be http or https" unless %w[http https].include?(uri.scheme)
      raise InvalidDsn, "missing host" if uri.host.blank?

      Target.new(
        scheme: uri.scheme,
        host: uri.host,
        port: (uri.port == uri.default_port) ? nil : uri.port
      )
    rescue URI::InvalidURIError => e
      raise InvalidDsn, "unparseable DSN: #{e.message}"
    end

    private

    # Sentry auth header format. Uses the project's own public_key so the
    # downstream Splat routes the event to the correct project.
    def auth_header(public_key)
      "Sentry sentry_version=7, sentry_client=splat-forwarder/1.0, sentry_key=#{public_key}"
    end
  end
end
