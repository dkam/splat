class CreateTransactionHourlyStats < ActiveRecord::Migration[8.1]
  # Companion to transaction_histograms. The histogram preserves the *duration
  # distribution* per endpoint/hour (so percentiles survive raw-row retention);
  # this table preserves the scalar aggregates the dashboard/MCP also need —
  # count, sums (for averages), max/min, query + N+1 + 5xx counts — so endpoint
  # stats and volume/avg sparklines keep working (and stay fast) after the raw
  # transactions are deleted. Retained on the same long clock as histograms.
  def change
    create_table :transaction_hourly_stats do |t|
      t.bigint :project_id, null: false
      t.string :transaction_name, null: false
      # Empty string for no-environment rows so the unique index treats them as
      # one bucket (SQLite makes NULLs distinct) — matches transaction_histograms.
      t.string :environment, null: false, default: ""
      t.datetime :hour_bucket, null: false

      t.bigint :count, null: false, default: 0
      t.bigint :sum_duration, null: false, default: 0
      t.integer :min_duration
      t.integer :max_duration, null: false, default: 0
      # db_time / view_time are nullable on transactions; track their own sample
      # counts so AVG matches raw AVG(col) (which skips NULLs) exactly.
      t.bigint :sum_db_time, null: false, default: 0
      t.bigint :db_time_count, null: false, default: 0
      t.bigint :sum_view_time, null: false, default: 0
      t.bigint :view_time_count, null: false, default: 0
      t.bigint :sum_query_count, null: false, default: 0
      t.integer :max_query_count, null: false, default: 0
      t.bigint :n_plus_one_count, null: false, default: 0
      t.bigint :error_count, null: false, default: 0
    end

    # ON CONFLICT target for both the live ingest bump and the hourly rollup.
    add_index :transaction_hourly_stats,
      [:project_id, :transaction_name, :environment, :hour_bucket],
      unique: true,
      name: "index_transaction_hourly_stats_unique"

    # Project-wide window scans (percentiles header, error rate, volume) and the
    # endpoint-ranking GROUP BY both walk a project's hour_bucket range.
    add_index :transaction_hourly_stats, [:project_id, :hour_bucket]
  end
end
