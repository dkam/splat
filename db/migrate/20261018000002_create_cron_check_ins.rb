# One row per monitor run, so a monitor can be drawn over time. cron_monitors
# keeps only the latest check-in: enough to say how a nightly job's one run in
# 24h went, but not an hourly job's other 23.
#
# A run's in_progress and its ok/error share a check_in_id and fill in one
# row. A heartbeat without an in_progress is a row of its own. A missed
# check-in is a row too (status "missed", started_at when it was due), written
# when Monitors::EvaluateJob first sees it. Retired on the events clock.
#
# On the primary DB beside cron_monitors. Booko's 19 monitors write about
# 6,000 rows a day, nearly all from its four every-minute heartbeats.
class CreateCronCheckIns < ActiveRecord::Migration[8.1]
  def change
    create_table :cron_check_ins do |t|
      t.references :cron_monitor, null: false, index: false, foreign_key: {on_delete: :cascade}
      t.integer :project_id, null: false
      t.string :check_in_id
      t.string :status, null: false
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.float :duration
      t.datetime :created_at, null: false
    end
    add_index :cron_check_ins, [:project_id, :started_at]
    add_index :cron_check_ins, [:cron_monitor_id, :check_in_id]
    add_index :cron_check_ins, :started_at
  end
end
