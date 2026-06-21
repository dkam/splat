# frozen_string_literal: true

class Issue < IssuesEventsRecord
  # project lives on the primary DB; AR can't JOIN across DBs but
  # `issue.project` is fine (one extra SELECT against primary).
  belongs_to :project
  has_many :events, dependent: :nullify

  enum :status, {open: 0, resolved: 1, ignored: 2}

  validates :fingerprint, presence: true, uniqueness: {scope: :project_id}
  validates :title, presence: true

  scope :recent, -> { order(last_seen: :desc) }
  scope :by_frequency, -> { order(count: :desc) }

  # Burst alerting: how often we recompute an issue's rate, and how long an
  # alert suppresses follow-ups for the same issue (one alert per hour).
  BURST_CHECK_INTERVAL = 30.seconds
  BURST_ALERT_DEDUP_WINDOW = 1.hour

  # Callbacks for email + ntfy notifications
  after_create :notify_new_issue, if: :should_notify_new_issue?
  after_update :notify_issue_reopened, if: :was_reopened?

  # Real-time updates
  after_create_commit do
    broadcast_refresh_to(project)
  end

  # Only refresh on meaningful changes. Without this guard, every Event#create
  # increments the counter_cache, which triggers an UPDATE here and would fire
  # both broadcasts unthrottled — bypassing Event's BROADCAST_THROTTLE.
  after_update_commit -> {
    broadcast_refresh
    broadcast_refresh_to(project, "issues")
  }, if: :saved_change_to_status?

  def self.group_event(event_payload, project, timestamp: Time.current)
    fingerprint = generate_fingerprint(event_payload)
    attempts = 0
    begin
      find_or_create_by!(project: project, fingerprint: fingerprint) do |issue|
        issue.title = extract_title(event_payload)
        issue.exception_type = extract_exception_type(event_payload)
        issue.first_seen = timestamp
        issue.last_seen = timestamp
        issue.status = :open
      end
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      # Race: another worker won the INSERT between our SELECT and our INSERT.
      # Retry once — the second find_by will see the committed row.
      attempts += 1
      retry if attempts < 2
      raise
    end
  end

  def self.generate_fingerprint(payload)
    # Use Sentry's fingerprint if provided
    if payload["fingerprint"].present?
      payload["fingerprint"].join("::")
    else
      # Generate from exception type + location
      type = payload.dig("exception", "values", 0, "type")
      file = payload.dig("exception", "values", 0, "stacktrace", "frames", -1, "filename")
      line = payload.dig("exception", "values", 0, "stacktrace", "frames", -1, "lineno")

      # Fallback to message if no exception
      if type.blank?
        message = payload["message"] || "Unknown Error"
        Digest::MD5.hexdigest(message)
      else
        "#{type}::#{file}::#{line}"
      end
    end
  end

  def self.extract_title(payload)
    payload.dig("exception", "values", 0, "value") ||
      payload["message"] ||
      payload.dig("exception", "values", 0, "type") ||
      "Unknown Error"
  end

  def self.extract_exception_type(payload)
    payload.dig("exception", "values", 0, "type")
  end

  def record_event!(timestamp: Time.current)
    update!(
      count: count + 1,
      last_seen: timestamp
    )
  end

  # Fire a burst alert (email + ntfy) when an open issue's event rate over the
  # last hour crosses the configured threshold. Throttled per issue so a flood
  # of events doesn't recompute the rate on every ingest. Called from
  # Event.create_from_sentry_payload! after the event is persisted.
  def maybe_alert_burst!
    return unless open?

    Rails.cache.fetch("burst_check:#{id}", expires_in: BURST_CHECK_INTERVAL) do
      setting = Setting.instance
      rate = events.where("timestamp >= ?", 1.hour.ago).count
      alert_burst!(rate: rate, setting: setting) if rate >= setting.burst_threshold
      true
    end
  rescue => e
    # Best-effort: an alerting hiccup must never fail (and retry) ingest.
    Rails.logger.warn("Issue#maybe_alert_burst! failed for issue=#{id}: #{e.class} #{e.message}")
  end

  # True while the issue is open and its most recent burst alert is still within
  # the dedup window — drives the index badge and the show-page banner.
  def bursting?
    open? && last_burst_at.present? && last_burst_at > BURST_ALERT_DEDUP_WINDOW.ago
  end

  private

  def alert_burst!(rate:, setting:)
    # write(unless_exist: true) is an atomic set-on-miss — returns false if the
    # key already exists, so concurrent workers don't double-fire within the
    # dedup window.
    return unless Rails.cache.write(
      "burst_alerted:#{id}", true,
      expires_in: BURST_ALERT_DEDUP_WINDOW, unless_exist: true
    )

    # update_columns skips callbacks/validations so this doesn't trigger the
    # status broadcast or touch updated_at semantics.
    update_columns(last_burst_at: Time.current, last_burst_rate: rate)
    IssueMailer.burst_detected(self, rate).deliver_later if email_notifications_enabled?
    NtfyNotificationJob.perform_later(id, "issue_burst") if setting.ntfy_configured?
  end

  def notify_new_issue
    IssueMailer.new_issue(self).deliver_later if email_notifications_enabled?
    NtfyNotificationJob.perform_later(id, "new_issue") if Setting.instance.ntfy_configured?
  end

  def notify_issue_reopened
    IssueMailer.issue_reopened(self).deliver_later
    NtfyNotificationJob.perform_later(id, "issue_reopened") if Setting.instance.ntfy_configured?
  end

  def should_notify_new_issue?
    email_notifications_enabled? || Setting.instance.ntfy_configured?
  end

  def email_notifications_enabled?
    # Only send email in production, or when explicitly enabled elsewhere.
    Rails.env.production? || ENV["SPLAT_EMAIL_NOTIFICATIONS"] == "true"
  end

  def was_reopened?
    # Check if status changed from resolved to open
    saved_change_to_status?(from: 1, to: 0)  # resolved=1, open=0
  end
end
