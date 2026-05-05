# frozen_string_literal: true

# Promotes query_count + has_n_plus_one out of measurements.query_analysis JSON
# and onto first-class columns. Aggregation queries (top_endpoints_by_impact,
# endpoints_by_n_plus_one) currently JSON-extract these per row × millions of
# rows; column-storage lets them dictionary/bit-pack and run in tens of ms.
#
# SQLite ADD COLUMN is O(1) — just appends to the row format, no rewrite.
class PromoteQuerySummaryToTransactionColumns < ActiveRecord::Migration[8.1]
  def change
    add_column :transactions, :query_count, :integer, default: 0, null: false
    add_column :transactions, :has_n_plus_one, :boolean, default: false, null: false
    add_index  :transactions, [:project_id, :has_n_plus_one], where: "has_n_plus_one = TRUE",
               name: "index_transactions_with_n_plus_one"
  end
end
