class AddTransactionNameTimestampIndex < ActiveRecord::Migration[8.1]
  def change
    # Per-endpoint reads (percentiles_for_endpoint, time_series_for_endpoint,
    # p95_by_bucket, the histogram_percentile raw arm) filter
    # `transaction_name = ? AND timestamp >= ? AND timestamp < ?`. With only the
    # single-column transaction_name index, SQLite seeks the name then scans the
    # endpoint's whole retention window filtering timestamp. This composite lets
    # it seek straight to the requested time slice. The standalone
    # transaction_name index is now a prefix of this one, so drop it.
    add_index :transactions, [:transaction_name, :timestamp]
    remove_index :transactions, :transaction_name
  end
end
