require "uri"
require "base64"

# Forwards a Sentry envelope to one or more second Splat (or Sentry) instances.
#
# Each project carries its own list of forward DSNs (Project#forward_dsns). A
# DSN supplies the *target host* only — scheme, host, port. Project identity
# (slug, public_key) is taken from the inbound request's project, so each app's
# events land in its own project on the downstream instance instead of all
# collapsing into the configured DSN's project. The downstream side needs to
# know about the project (pre-seeded or auto-created via SPLAT_AUTO_CREATE_SLUGS
# — see DsnAuthenticationService).
#
# Forwarding is two-phase: `forward` runs in the ingest request and only
# *enqueues* a job on the FORWARD_TUBE; `deliver` runs in the background
# consumer (Ingest::ForwardConsumer) and does the actual HTTP POST per DSN.
# That keeps N targets × timeouts off the request path.
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
    # Request-path entry point: enqueue a background forward job carrying the
    # raw envelope and the project's target DSNs. No-op when the project has no
    # forward targets. Never raises into the ingest path.
    def forward(raw_body, project:, content_type: "application/x-sentry-envelope")
      return unless project.forwarding?

      encoded = Base64.strict_encode64(raw_body)

      Ingest::Tuber.put(
        Ingest::Tuber::FORWARD_TUBE,
        {
          project_id: project.id,
          # Envelopes can carry binary items; base64 keeps the JSON job valid.
          body: encoded,
          content_type: content_type,
          dsns: project.forward_dsns
        }
      )
    rescue => e
      # Most likely cause is tuber rejecting an oversized job (beanstalkd's
      # default cap is 64 KB). Log the encoded size so the rejection is
      # diagnosable — the envelope is still ingested, it just isn't forwarded.
      Rails.logger.warn("EnvelopeForwarder: enqueue failed for project=#{project.slug} (encoded #{encoded&.bytesize}B): #{e.class} #{e.message}")
    end

    # Consumer-side: POST the raw envelope to a single downstream DSN, keeping
    # the project's own slug + public_key. Returns true on a 2xx, false on a
    # logged failure (best-effort — callers don't retry).
    def deliver(raw_body, dsn:, project:, content_type: "application/x-sentry-envelope")
      req = outbound_request(dsn, project)

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
        Rails.logger.warn("EnvelopeForwarder: upstream returned #{response.status} for project=#{project.slug} dsn=#{req[:url]}")
      end
      response.success?
    rescue InvalidDsn => e
      Rails.logger.warn("EnvelopeForwarder: invalid DSN #{dsn.inspect} (#{e.message})")
      false
    rescue Faraday::Error => e
      Rails.logger.warn("EnvelopeForwarder: forward failed for project=#{project.slug}: #{e.class} #{e.message}")
      false
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

    # Parses a forward DSN. Only scheme/host/port are used at forward time —
    # the embedded key/project_id are ignored (kept here so the operator can
    # paste a real DSN string into the project's forwarding settings).
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
