# frozen_string_literal: true

# When each config/schedule.yml entry last ran, written by the worker that
# picked its job up. It's the one record that doesn't care what fired the job —
# tuber's scheduler or bin/scheduler — so it's what the settings page and
# /_health check to tell whether anything is running the schedule at all.
class CreateScheduleRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :schedule_runs do |t|
      t.string :name, null: false
      t.datetime :last_run_at, null: false
    end
    add_index :schedule_runs, :name, unique: true
  end
end
