require "uri"
require "base64"

# Forwards a Sentry envelope to one or more downstream Splat (or Sentry)
# instances — a relay.
#
# Each project carries its own list of forward DSNs (Project#forward_dsns).
# Each DSN fully specifies its target: scheme/host/port, the downstream
# project's public key, and the downstream project slug. Splat forwards exactly
# as a Sentry SDK pointed at that DSN would — events land in the DSN's own
# project, authenticated by the DSN's own key. No shared secret and no
# cross-instance key sync: the downstream just sees an ordinary client request.
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

  # A parsed forward DSN. envelope_url targets the DSN's *own* project; key is
  # the DSN's public key, sent as the downstream X-Sentry-Auth credential.
  Target = Struct.new(:scheme, :host, :port, :key, :project) do
    def envelope_url
      port_part = port ? ":#{port}" : ""
      "#{scheme}://#{host}#{port_part}/api/#{project}/envelope/"
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

    # Consumer-side: POST the raw envelope to one downstream DSN, using that
    # DSN's own project + key. Returns true on a 2xx, false on a logged failure
    # (best-effort — callers don't retry). `project` is the *source* project,
    # passed only for log context.
    def deliver(raw_body, dsn:, project:, content_type: "application/x-sentry-envelope")
      req = outbound_request(dsn)

      conn = Faraday.new(url: req[:url]) do |f|
        f.options.timeout = TIMEOUT_SECONDS
        f.options.open_timeout = TIMEOUT_SECONDS
      end

      response = conn.post do |r|
        r.headers["Content-Type"] = content_type
        r.headers["X-Sentry-Auth"] = req[:auth_header]
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

    # Build the outbound URL + X-Sentry-Auth from a forward DSN. Exposed so
    # tests can verify forwarding identity without a real HTTP round trip.
    def outbound_request(forward_dsn)
      target = parse_dsn(forward_dsn)
      {
        url: target.envelope_url,
        auth_header: auth_header(target.key)
      }
    end

    # Parse a forward DSN: scheme://public_key@host[:port]/project-slug. Every
    # part is used — a relay DSN must name the downstream project and key, so a
    # host-only entry is rejected (caught at save by Project validation, not
    # silently in the background consumer).
    def parse_dsn(string)
      uri = URI.parse(string)
      raise InvalidDsn, "must be http or https" unless %w[http https].include?(uri.scheme)
      raise InvalidDsn, "missing host" if uri.host.blank?

      key = uri.user
      raise InvalidDsn, "missing public key" if key.blank?

      project = uri.path.to_s.delete_prefix("/")
      raise InvalidDsn, "missing project" if project.blank?

      Target.new(
        scheme: uri.scheme,
        host: uri.host,
        port: (uri.port == uri.default_port) ? nil : uri.port,
        key: key,
        project: project
      )
    rescue URI::InvalidURIError => e
      raise InvalidDsn, "unparseable DSN: #{e.message}"
    end

    private

    # Sentry auth header carrying the downstream project's public key so the
    # downstream Splat routes the event to that project.
    def auth_header(public_key)
      "Sentry sentry_version=7, sentry_client=splat-forwarder/1.0, sentry_key=#{public_key}"
    end
  end
end
