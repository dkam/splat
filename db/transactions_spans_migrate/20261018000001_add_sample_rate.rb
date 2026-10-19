# The share of transactions the SDK kept, from the envelope's trace header
# (the dynamic sampling context's sample_rate), and the hourly sums scaled back
# up by it: each transaction stands for 1 / sample_rate of them.
#
# Backfill-free: old transactions stay NULL (the rate wasn't kept), and old
# hourly rows leave est_count at 0, which the readers take to mean "as
# recorded" — count and sum_duration stand in for the estimates.
class AddSampleRate < ActiveRecord::Migration[8.1]
  def change
    add_column :transactions, :sample_rate, :float
    add_column :transaction_hourly_stats, :est_count, :float, default: 0, null: false
    add_column :transaction_hourly_stats, :est_sum_duration, :float, default: 0, null: false
    add_column :transaction_hourly_stats, :rated_count, :bigint, default: 0, null: false
  end
end
