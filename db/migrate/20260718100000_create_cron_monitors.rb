# frozen_string_literal: true

class CreateCronMonitors < ActiveRecord::Migration[8.1]
  def change
    create_table :cron_monitors do |t|
      t.integer :project_id, null: false
      t.string :slug, null: false

      # Schedule, flattened from the check-in's monitor_config. checkin_margin
      # and max_runtime are minutes, matching Sentry's units.
      t.string :schedule_type   # "interval" | "crontab"
      t.string :schedule_value  # interval count, or a crontab expression
      t.string :schedule_unit   # interval only: minute/hour/day/week/month/year
      t.integer :checkin_margin
      t.integer :max_runtime
      t.string :timezone
      t.json :config            # raw monitor_config as last received

      # Latest check-in, upserted in place — no per-check-in history rows.
      t.string :last_status     # in_progress | ok | error
      t.datetime :last_checkin_at
      t.datetime :last_ok_at
      t.datetime :in_progress_since
      t.float :last_duration    # seconds
      t.string :environment

      # Evaluator verdict: unknown | ok | missed | error | overrun
      t.string :state, null: false, default: "unknown"

      t.timestamps
    end

    add_index :cron_monitors, [:project_id, :slug], unique: true
    add_foreign_key :cron_monitors, :projects
  end
end
