# frozen_string_literal: true

class Issue < ApplicationRecord
  belongs_to :project
  has_many :events, dependent: :nullify

  enum :status, { open: 0, resolved: 1, ignored: 2 }

  validates :fingerprint, presence: true, uniqueness: { scope: :project_id }
  validates :title, presence: true

  scope :recent, -> { order(last_seen: :desc) }
  scope :by_frequency, -> { order(count: :desc) }

  # Callbacks for email notifications
  after_create :notify_new_issue, if: :should_notify_new_issue?
  after_update :notify_issue_reopened, if: :was_reopened?

  # Real-time updates
  after_create_commit do
    broadcast_refresh_to(project)
  end

  after_update_commit do
    broadcast_refresh  # Refreshes the issue show page
    broadcast_refresh_to(project, "issues")  # Refreshes the project's issues index
  end

  # Broadcast to both project and issue when status changes
  # after_update_commit -> {
  #  broadcast_refresh_later               # For issue show pages
  #  broadcast_refresh_later_to(project)  # For project pages
  # } #, if: :status_changed?

  def self.group_event(event_payload, project)
    fingerprint = generate_fingerprint(event_payload)

    find_or_create_by(project: project, fingerprint: fingerprint) do |issue|
      issue.title = extract_title(event_payload)
      issue.exception_type = extract_exception_type(event_payload)
      issue.first_seen = Time.current
      issue.last_seen = Time.current
      issue.status = :open
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

  private

  def notify_new_issue
    IssueMailer.new_issue(self).deliver_later
  end

  def notify_issue_reopened
    IssueMailer.issue_reopened(self).deliver_later
  end

  def should_notify_new_issue?
    # Only notify for new issues in production environment or if explicitly enabled
    Rails.env.production? || ENV['SPLAT_EMAIL_NOTIFICATIONS'] == 'true'
  end

  def was_reopened?
    # Check if status changed from resolved to open
    saved_change_to_status?(from: 1, to: 0)  # resolved=1, open=0
  end
end
