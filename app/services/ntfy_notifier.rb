require "uri"

# Sends issue notifications to an ntfy (https://ntfy.sh) topic.
#
# Setting.ntfy_url is the full topic URL — e.g. "https://ntfy.sh/my-splat"
# or "https://ntfy.example.com/alerts". Auth is optional; supply
# Setting.ntfy_token for a Bearer-protected topic.
#
# Failures are logged, never raised — notification is best-effort and must
# never block ingest or the request that created the issue.
class NtfyNotifier
  class InvalidUrl < StandardError; end

  TIMEOUT_SECONDS = 3

  VALID_PRIORITIES = %w[min low default high max].freeze

  EVENTS = {
    "new_issue"      => { subject: "New Issue",      tags: %w[boom warning] },
    "issue_reopened" => { subject: "Issue Reopened", tags: %w[recycle warning] },
    "issue_burst"    => { subject: "Issue Burst",    tags: %w[fire warning] }
  }.freeze

  class << self
    def notify_new_issue(issue)
      deliver(issue, "new_issue")
    end

    def notify_issue_reopened(issue)
      deliver(issue, "issue_reopened")
    end

    def notify_issue_burst(issue)
      deliver(issue, "issue_burst")
    end

    def parse_url(url)
      raise InvalidUrl, "blank URL" if url.blank?

      uri = URI.parse(url)
      raise InvalidUrl, "scheme must be http(s)" unless %w[http https].include?(uri.scheme)
      raise InvalidUrl, "missing host" if uri.host.blank?
      raise InvalidUrl, "missing topic path" if uri.path.blank? || uri.path == "/"

      uri
    rescue URI::InvalidURIError => e
      raise InvalidUrl, e.message
    end

    # Pure builder — returns the URL, headers, and body for an ntfy POST.
    # Exposed so tests can verify the request shape without an HTTP round trip.
    def outbound_request(issue, event_key, setting: Setting.instance)
      meta = EVENTS.fetch(event_key)
      uri = parse_url(setting.ntfy_url)

      headers = {
        "Content-Type" => "text/plain; charset=utf-8",
        "Title"        => "[Splat] #{meta[:subject]}: #{issue.title}",
        "Priority"     => setting.ntfy_priority.presence || "default",
        "Tags"         => meta[:tags].join(",")
      }
      click = issue_url(issue)
      headers["Click"] = click if click.present?
      headers["Authorization"] = "Bearer #{setting.ntfy_token}" if setting.ntfy_token.present?

      {
        url: uri.to_s,
        headers: headers,
        body: build_message(issue, event_key: event_key)
      }
    end

    private

    def deliver(issue, event_key)
      setting = Setting.instance
      return unless setting.ntfy_configured?

      req = outbound_request(issue, event_key, setting: setting)

      conn = Faraday.new do |f|
        f.options.timeout = TIMEOUT_SECONDS
        f.options.open_timeout = TIMEOUT_SECONDS
      end

      response = conn.post(req[:url]) do |r|
        req[:headers].each { |k, v| r.headers[k] = v }
        r.body = req[:body]
      end

      unless response.success?
        Rails.logger.warn("NtfyNotifier: ntfy returned #{response.status} for issue=#{issue.id}")
      end
    rescue InvalidUrl => e
      Rails.logger.warn("NtfyNotifier: invalid ntfy_url configured (#{e.message})")
    rescue Faraday::Error => e
      Rails.logger.warn("NtfyNotifier: send failed: #{e.class} #{e.message}")
    end

    def build_message(issue, event_key:)
      header =
        case event_key
        when "issue_reopened" then "Reopened (#{issue.count} events total)"
        when "issue_burst"    then "Bursting at #{issue.last_burst_rate.to_i} events/hr"
        else "New issue"
        end

      [
        header,
        "Project: #{issue.project&.name}",
        "Type: #{issue.exception_type || 'n/a'}",
        issue.title.to_s
      ].compact_blank.join("\n")
    end

    def issue_url(issue)
      return nil unless issue.persisted? && issue.project&.persisted?

      host = ENV.fetch("SPLAT_HOST", "localhost:3000")
      scheme = host.include?("localhost") ? "http" : "https"
      # Routes nest issues under projects with `param: :slug`, and Project doesn't
      # override to_param — pass the slug explicitly so the URL is routable.
      Rails.application.routes.url_helpers.project_issue_url(
        issue.project.slug, issue, host: host, protocol: scheme
      )
    rescue StandardError
      nil
    end
  end
end
