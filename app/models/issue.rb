# frozen_string_literal: true

class Issue < ApplicationRecord
  belongs_to :project
  has_many :events, dependent: :nullify

  validates :fingerprint, presence: true, uniqueness: { scope: :project_id }
  validates :title, presence: true
  validates :status, inclusion: { in: %w[unresolved resolved ignored] }

  scope :unresolved, -> { where(status: "unresolved") }
  scope :resolved, -> { where(status: "resolved") }
  scope :ignored, -> { where(status: "ignored") }
  scope :recent, -> { order(last_seen: :desc) }
  scope :by_frequency, -> { order(count: :desc) }

  def self.group_event(event_payload, project)
    fingerprint = generate_fingerprint(event_payload)

    find_or_create_by(project: project, fingerprint: fingerprint) do |issue|
      issue.title = extract_title(event_payload)
      issue.exception_type = extract_exception_type(event_payload)
      issue.first_seen = Time.current
      issue.last_seen = Time.current
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

  def resolve!
    update!(status: "resolved")
  end

  def ignore!
    update!(status: "ignored")
  end

  def unresolve!
    update!(status: "unresolved")
  end

  def resolved?
    status == "resolved"
  end

  def ignored?
    status == "ignored"
  end

  def unresolved?
    status == "unresolved"
  end
end
