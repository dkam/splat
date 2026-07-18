# frozen_string_literal: true

# A Sentry Crons monitor: one row per monitor_slug per project, upserted in
# place from check-in envelope items (no per-check-in history — the latest
# check-in IS the record, which keeps the write load at one tiny primary-DB
# UPDATE per heartbeat).
#
# The schedule comes from the check-in's monitor_config: the first check-in
# auto-registers the monitor, and later config changes update it. Monitors that
# never send a monitor_config are still tracked (last seen / last status) but
# can't be evaluated for missed check-ins — there's nothing to expect.
#
# Monitors::EvaluateJob sweeps this table periodically and opens Issues via
# the normal alert path when a monitor goes silent, errors, or overruns.
class CronMonitor < ApplicationRecord
  belongs_to :project

  STATUSES = %w[in_progress ok error].freeze

  # Evaluator verdicts. `unknown` = never evaluated or no schedule to evaluate
  # against; the rest mirror the failure kinds (see Monitors::EvaluateJob).
  STATES = %w[unknown ok missed error overrun].freeze

  # Sentry's default when monitor_config omits checkin_margin (minutes).
  DEFAULT_CHECKIN_MARGIN_MINUTES = 1

  INTERVAL_UNIT_SECONDS = {
    "minute" => 60,
    "hour" => 3_600,
    "day" => 86_400,
    "week" => 604_800,
    "month" => 2_592_000,
    "year" => 31_536_000
  }.freeze

  validates :slug, presence: true, uniqueness: {scope: :project_id}
  validates :state, inclusion: {in: STATES}

  scope :by_slug, -> { order(:slug) }

  # Ingest path (Ingest::CheckInConsumer). One find + one INSERT/UPDATE on
  # primary per check-in. Returns nil for payloads not worth recording.
  def self.record_check_in!(payload, project)
    return nil unless payload.is_a?(Hash)

    slug = payload["monitor_slug"].to_s.strip
    status = payload["status"].to_s
    return nil if slug.blank? || STATUSES.exclude?(status)

    monitor = find_or_initialize_by(project: project, slug: slug)
    monitor.apply_config(payload["monitor_config"]) if payload["monitor_config"].is_a?(Hash)

    now = Time.current
    monitor.last_status = status
    monitor.last_checkin_at = now
    monitor.environment = payload["environment"] if payload["environment"].present?

    case status
    when "in_progress"
      # Each in_progress marks the start of a new run (overrun clock).
      monitor.in_progress_since = now
    when "ok"
      monitor.last_ok_at = now
      monitor.in_progress_since = nil
      monitor.last_duration = payload["duration"] if payload["duration"].is_a?(Numeric)
    when "error"
      monitor.in_progress_since = nil
      monitor.last_duration = payload["duration"] if payload["duration"].is_a?(Numeric)
    end

    monitor.save!
    monitor
  rescue ActiveRecord::RecordNotUnique
    # Race with another writer on the same new slug: retry resolves to UPDATE.
    retry
  end

  def apply_config(config)
    schedule = config["schedule"].is_a?(Hash) ? config["schedule"] : {}
    self.schedule_type = schedule["type"]
    self.schedule_value = schedule["value"].to_s.presence
    self.schedule_unit = schedule["unit"]
    self.checkin_margin = config["checkin_margin"]
    self.max_runtime = config["max_runtime"]
    self.timezone = config["timezone"]
    self.config = config
  end

  def interval_seconds
    return nil unless schedule_type == "interval"
    unit = INTERVAL_UNIT_SECONDS[schedule_unit.to_s]
    value = schedule_value.to_i
    return nil unless unit && value.positive?
    value * unit
  end

  def margin_seconds
    margin = checkin_margin.to_i
    margin = DEFAULT_CHECKIN_MARGIN_MINUTES unless margin.positive?
    margin * 60
  end

  # When the next check-in was due (margin not included), based on the most
  # recent check-in of any status — a service erroring on schedule is still
  # checking in; silence is what "missed" means. nil when the schedule is
  # unknown or unparsable, in which case missed? can never fire.
  def next_expected_at
    basis = last_checkin_at || created_at
    return nil unless basis

    case schedule_type
    when "interval"
      seconds = interval_seconds
      seconds && basis + seconds
    when "crontab"
      cron = Fugit.parse_cron(schedule_value.to_s)
      return nil unless cron
      from = timezone.present? ? basis.in_time_zone(timezone) : basis
      cron.next_time(from)&.to_t
    end
  rescue ArgumentError
    # Unknown timezone string — treat the schedule as unevaluable.
    nil
  end

  def missed?(now = Time.current)
    due = next_expected_at
    due.present? && now > due + margin_seconds
  end

  def erroring?
    last_status == "error"
  end

  def overrun?(now = Time.current)
    in_progress_since.present? &&
      max_runtime.to_i.positive? &&
      now > in_progress_since + max_runtime.to_i.minutes
  end

  # Human description of the schedule for the UI and issue titles.
  def schedule_description
    case schedule_type
    when "interval"
      "every #{schedule_value} #{schedule_unit.to_s.pluralize(schedule_value.to_i)}"
    when "crontab"
      "cron #{schedule_value}"
    else
      "no schedule"
    end
  end
end
