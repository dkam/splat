require "uri"

# Sends issue alerts — a new issue, one reopened, a burst — as a POST to
# Setting.webhook_url. Setting.webhook_format is the body:
#
# - "json": Splat's own, for anything that takes a webhook. Signed with
#   Setting.webhook_secret, when there is one, as
#   X-Splat-Signature: sha256=<HMAC-SHA256 of the body>.
# - "slack": an incoming-webhook message.
# - "discord": a webhook message, mentioning no one.
#
# Failures are logged, never raised, as NtfyNotifier's are.
class WebhookNotifier
  class InvalidUrl < StandardError; end

  TIMEOUT_SECONDS = 3
  FORMATS = %w[json slack discord].freeze

  # Discord refuses a message over this.
  DISCORD_LIMIT = 2000

  HEADINGS = {
    "new_issue" => "New issue",
    "issue_reopened" => "Issue reopened",
    "issue_burst" => "Issue bursting"
  }.freeze

  class << self
    def notify_new_issue(issue) = deliver(issue, "new_issue")
    def notify_issue_reopened(issue) = deliver(issue, "issue_reopened")
    def notify_issue_burst(issue) = deliver(issue, "issue_burst")

    def parse_url(url)
      raise InvalidUrl, "blank URL" if url.blank?

      uri = URI.parse(url)
      raise InvalidUrl, "scheme must be http(s)" unless %w[http https].include?(uri.scheme)
      raise InvalidUrl, "missing host" if uri.host.blank?

      uri
    rescue URI::InvalidURIError => e
      raise InvalidUrl, e.message
    end

    # The URL, headers and body of the POST, without sending it.
    def outbound_request(issue, event_key, setting: Setting.instance)
      uri = parse_url(setting.webhook_url)
      body =
        case setting.webhook_format
        when "slack" then {text: slack_text(issue, event_key)}
        when "discord" then {content: discord_content(issue, event_key), allowed_mentions: {parse: []}}
        else json_body(issue, event_key)
        end.to_json

      headers = {
        "Content-Type" => "application/json",
        "User-Agent" => "Splat/#{Splat::VERSION}",
        "X-Splat-Event" => event_key
      }
      if setting.webhook_secret.present?
        headers["X-Splat-Signature"] = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", setting.webhook_secret, body)}"
      end

      {url: uri.to_s, headers: headers, body: body}
    end

    private

    def deliver(issue, event_key)
      setting = Setting.instance
      return unless setting.webhook_configured?

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
        Rails.logger.warn("WebhookNotifier: #{req[:url]} returned #{response.status} for issue=#{issue.id}")
      end
    rescue InvalidUrl => e
      Rails.logger.warn("WebhookNotifier: invalid webhook_url configured (#{e.message})")
    rescue Faraday::Error => e
      Rails.logger.warn("WebhookNotifier: send failed: #{e.class} #{e.message}")
    end

    def json_body(issue, event_key)
      project = issue.project
      {
        event: event_key,
        project: {id: project&.id, slug: project&.slug, name: project&.name},
        issue: {
          id: issue.id,
          title: issue.title,
          headline: issue.headline,
          exception_type: issue.exception_type,
          status: issue.status,
          count: issue.count,
          first_seen: issue.first_seen&.utc&.iso8601,
          last_seen: issue.last_seen&.utc&.iso8601,
          burst_rate: (issue.last_burst_rate&.to_i if event_key == "issue_burst"),
          url: IssueLink.url(issue)
        }.compact
      }
    end

    # Slack's mrkdwn: a link is <url|text>, and &, < and > are escaped.
    def slack_text(issue, event_key)
      headline = slack_escape(issue.headline.to_s)
      link = (url = IssueLink.url(issue)) ? "<#{url}|#{headline}>" : headline
      ["*[Splat] #{HEADINGS.fetch(event_key)}* in #{slack_escape(issue.project&.name.to_s)}: #{link}",
        details(issue, event_key)].join("\n")
    end

    def slack_escape(text) = text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")

    def discord_content(issue, event_key)
      url = IssueLink.url(issue)
      first = "**[Splat] #{HEADINGS.fetch(event_key)}** in #{issue.project&.name}: "
      rest = "\n#{details(issue, event_key)}#{"\n<#{url}>" if url}"
      room = DISCORD_LIMIT - first.length - rest.length
      first + issue.headline.to_s.truncate([room, 1].max) + rest
    end

    def details(issue, event_key)
      [issue.exception_type.presence,
        (event_key == "issue_burst") ? "#{issue.last_burst_rate.to_i} events/hr" : "#{issue.count} events"].compact.join(" · ")
    end
  end
end
