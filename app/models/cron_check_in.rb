# frozen_string_literal: true

# One run of a cron monitor: opened by an in_progress check-in, closed by the
# ok or error that shares its check_in_id, or both at once for a heartbeat
# that only reports the end. "missed" rows mark a check-in that never came, at
# the time it was due. See CronMonitor#record_run!.
class CronCheckIn < ApplicationRecord
  belongs_to :cron_monitor

  STATUSES = %w[in_progress ok error missed].freeze

  validates :status, inclusion: {in: STATUSES}

  # Runs that overlap the window. A run is found by when it started, so the
  # lower bound reaches back a day for one that began before the window and
  # was still going inside it.
  scope :overlapping, ->(range) {
    where(started_at: (range.begin - 1.day)...range.end)
      .where("finished_at IS NULL OR finished_at >= ? OR started_at >= ?", range.begin, range.begin)
  }
end
