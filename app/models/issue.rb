# frozen_string_literal: true

class Issue < IssuesEventsRecord
  # project lives on the primary DB; AR can't JOIN across DBs but
  # `issue.project` is fine (one extra SELECT against primary).
  belongs_to :project
  has_many :events, dependent: :nullify
  has_many :issue_facets, dependent: :delete_all

  enum :status, {open: 0, resolved: 1, ignored: 2}

  validates :fingerprint, presence: true, uniqueness: {scope: :project_id}
  validates :title, presence: true

  scope :recent, -> { order(last_seen: :desc) }
  scope :by_frequency, -> { order(count: :desc) }

  # Free-text match on title/exception type. `%` and `_` are escaped and an
  # explicit ESCAPE clause is set — error text is full of underscores
  # (`undefined method '_dump'`), and unescaped they'd silently match any
  # character, returning issues that don't contain the search text at all.
  scope :matching_text, ->(query) {
    pattern = "%#{sanitize_sql_like(query.to_s)}%"
    where("title LIKE :q ESCAPE '\\' OR exception_type LIKE :q ESCAPE '\\'", q: pattern)
  }

  # "Seen in", not "belongs to": an issue groups events across environments and
  # releases, so these match an issue with at least one event carrying the
  # value. Backed by issue_facets (see IssueFacet) — a subquery on an indexed
  # tiny table, never a scan over events.
  scope :seen_in, ->(name, value, project_id: nil) {
    where(id: IssueFacet.issue_ids_for(name, value, project_id: project_id))
  }
  scope :seen_in_environment, ->(env, project_id: nil) { seen_in(:environment, env, project_id: project_id) }
  scope :seen_in_release, ->(release, project_id: nil) { seen_in(:release, release, project_id: project_id) }

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
    rekey_root_cause_issue(event_payload, project, fingerprint)
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
      exception_fingerprint(SentryProtocol::Payload.raised_exception(payload), SentryProtocol::Payload.stacktrace(payload)) ||
        # Fallback to message if no exception
        Digest::MD5.hexdigest(SentryProtocol::Payload.message_template(payload).to_s.presence || "Unknown Error")
    end
  end

  # Exception type + the innermost frame of the stack trace it was raised
  # with; nil without a type.
  def self.exception_fingerprint(exception, stacktrace)
    type = exception&.dig("type")
    return if type.blank?

    frame = stacktrace&.dig("frames")&.last || {}
    "#{type}::#{frame["filename"]}::#{frame["lineno"]}"
  end

  def self.extract_title(payload)
    exception = SentryProtocol::Payload.raised_exception(payload) || {}
    exception["value"].presence ||
      SentryProtocol::Payload.message(payload) ||
      exception["type"].presence ||
      "Unknown Error"
  end

  def self.extract_exception_type(payload)
    SentryProtocol::Payload.raised_exception(payload)&.dig("type")
  end

  # Splat used to group a chained exception by its root cause, values[0],
  # rather than the exception raised. An issue keyed that way is re-keyed by
  # the first event to match it, so the change of grouping doesn't open every
  # existing wrapped-error issue again as new — and email about each one.
  def self.rekey_root_cause_issue(payload, project, fingerprint)
    return if payload["fingerprint"].present?

    root_cause = SentryProtocol::Payload.root_cause(payload)
    old_fingerprint = exception_fingerprint(root_cause, root_cause&.dig("stacktrace"))
    return if old_fingerprint.nil? || old_fingerprint == fingerprint
    return if exists?(project: project, fingerprint: fingerprint)

    where(project: project, fingerprint: old_fingerprint).update_all(
      fingerprint: fingerprint,
      title: extract_title(payload),
      exception_type: extract_exception_type(payload),
      updated_at: Time.current
    )
  end

  # The title's message line, and the error_highlight snippet after it (nil
  # for a one-line title). See ExceptionMessage.
  def headline
    ExceptionMessage.headline(title)
  end

  def title_detail
    ExceptionMessage.detail(title)
  end

  def record_event!(timestamp: Time.current)
    update!(
      count: count + 1,
      last_seen: timestamp
    )
  end

  # Denormalise an event's environment/release onto this issue so the "seen in"
  # filters don't have to DISTINCT over events. Throttled per (issue, name,
  # value). Called from Event.create_from_sentry_payload! after the event is
  # persisted, alongside maybe_alert_burst!.
  def harvest_facets!(environment:, release:, seen_at:)
    IssueFacet.harvest!(
      project_id: project_id,
      issue_id: id,
      values: {environment: environment, release: release},
      seen_at: seen_at
    )
  rescue => e
    # Best-effort: a filter-index miss must never fail (and retry) ingest.
    Rails.logger.warn("Issue#harvest_facets! failed for issue=#{id}: #{e.class} #{e.message}")
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
