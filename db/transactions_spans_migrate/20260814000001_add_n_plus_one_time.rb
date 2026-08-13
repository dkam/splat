# Duration weighting for N+1 findings: transactions carry the summed db-span
# time of their flagged patterns, and the hourly aggregate sums it per endpoint
# so the N+1 page can rank by wasted time instead of prevalence.
#
# Both are backfill-free by design: old transactions stay NULL (unknown, not
# zero), and old hourly rows stay 0 — the ranking falls back to affected-count
# order until timed rows accumulate.
class AddNPlusOneTime < ActiveRecord::Migration[8.1]
  def change
    add_column :transactions, :n_plus_one_time, :integer
    add_column :transaction_hourly_stats, :sum_n_plus_one_time, :bigint, default: 0, null: false
  end
end
