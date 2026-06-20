class CreateTransactionHistograms < ActiveRecord::Migration[8.1]
  def change
    create_table :transaction_histograms do |t|
      t.bigint :project_id, null: false
      t.string :transaction_name, null: false
      # Empty string for transactions with no environment so the unique
      # index treats them as a single bucket (SQLite makes NULLs distinct).
      t.string :environment, null: false, default: ""
      t.datetime :hour_bucket, null: false
      t.integer :bucket_index, null: false
      t.integer :count, null: false
    end

    # ON CONFLICT target for the hourly rollup INSERT … SELECT … GROUP BY.
    # Rebuilding the same hour overwrites the row.
    add_index :transaction_histograms,
              [:project_id, :transaction_name, :environment, :hour_bucket, :bucket_index],
              unique: true,
              name: "index_transaction_histograms_unique"

    # Global rollups (across all endpoints) walk the hour_bucket range.
    add_index :transaction_histograms, [:project_id, :hour_bucket]
  end
end
