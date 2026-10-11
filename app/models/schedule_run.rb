# frozen_string_literal: true

# When a worker last started each config/schedule.yml entry. See
# Ingest::ScheduleStatus for what reads it.
class ScheduleRun < ApplicationRecord
  # Never raises: the job it's recorded for matters more than the record. A
  # write lost to a locked database shows up as a late entry, not a failed job.
  def self.record!(name, at: Time.current)
    upsert({name: name.to_s, last_run_at: at}, unique_by: :name)
  rescue => e
    Rails.logger.warn "[ScheduleRun] couldn't record a run of #{name}: #{e.class}: #{e.message}"
  end

  # {name => last_run_at}
  def self.last_runs
    pluck(:name, :last_run_at).to_h
  end
end
