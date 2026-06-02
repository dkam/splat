# frozen_string_literal: true

class Issue < ApplicationRecord
  belongs_to :project
  has_many :events, dependent: :nullify

  enum :status, { open: 0, resolved: 1, ignored: 2 }

  validates :fingerprint, presence: true, uniqueness: { scope: :project_id }
  validates :title, presence: true

  scope :recent, -> { order(last_seen: :desc) }
  scope :by_frequency, -> { order(count: :desc) }

  # Callbacks for notifications (email + ntfy)
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

  # How often to recompute the hourly rate per issue. Cache marker keeps
  # subsequent calls within the interval out of the (DB-touching) block.
  BURST_CHECK_INTERVAL = 30.seconds

  # How long to suppress duplicate spike alerts for the same issue. Detection
  # may fire many times during a sustained spike; we only want one email +
  # ntfy notification per spike-episode.
  BURST_ALERT_DEDUP_WINDOW = 1.hour

  def maybe_alert_burst!
    return unless open?

    Rails.cache.fetch("burst_check:#{id}", expires_in: BURST_CHECK_INTERVAL) do
      setting = Setting.instance
      rate = events.where("timestamp >= ?", 1.hour.ago).count
      if rate >= setting.auto_ignore_threshold
        alert_burst!(rate: rate, setting: setting)
        auto_ignore_for_burst!(rate: rate) if setting.auto_ignore_enabled
      end
      true
    end
  end

  def to_ducklake_row
    {
      id: id,
      project_id: project_id,
      fingerprint: fingerprint,
      title: title,
      exception_type: exception_type,
      status: Issue.statuses[status],
      count: count,
      first_seen: first_seen,
      last_seen: last_seen,
      created_at: created_at,
      updated_at: updated_at
    }
  end

  private

  def alert_burst!(rate:, setting:)
    # write(unless_exist: true) is an atomic set-on-miss — returns false if
    # the key already exists, so concurrent workers don't double-fire.
    return unless Rails.cache.write(
      "burst_alerted:#{id}", true,
      expires_in: BURST_ALERT_DEDUP_WINDOW, unless_exist: true
    )

    update_columns(auto_ignore_rate: rate)
    IssueMailer.burst_detected(self, rate).deliver_later
    NtfyNotificationJob.perform_later(id, "issue_burst") if setting.ntfy_configured?
  end

  def auto_ignore_for_burst!(rate:)
    update!(status: :ignored, auto_ignored_at: Time.current, auto_ignore_rate: rate)
  end

  def notify_new_issue
    IssueMailer.new_issue(self).deliver_later if email_notifications_enabled?
    NtfyNotificationJob.perform_later(id, "new_issue") if Setting.instance.ntfy_configured?
  end

  def notify_issue_reopened
    IssueMailer.issue_reopened(self).deliver_later
    NtfyNotificationJob.perform_later(id, "issue_reopened") if Setting.instance.ntfy_configured?
  end

  # Fire the new-issue callback whenever email *or* ntfy wants it; each
  # channel re-checks its own gate inside #notify_new_issue.
  def should_notify_new_issue?
    email_notifications_enabled? || Setting.instance.ntfy_configured?
  end

  def email_notifications_enabled?
    # Only notify for new issues in production environment or if explicitly enabled
    Rails.env.production? || ENV['SPLAT_EMAIL_NOTIFICATIONS'] == 'true'
  end

  def was_reopened?
    # Check if status changed from resolved to open
    saved_change_to_status?(from: 1, to: 0)  # resolved=1, open=0
  end
end
