class CreateTransactions < ActiveRecord::Migration[8.1]
  def change
    create_table :transactions do |t|
      t.string :transaction_id, null: false
      t.integer :project_id, null: false
      t.datetime :timestamp, null: false
      t.string :transaction_name, null: false
      t.string :op
      t.integer :duration, null: false
      t.integer :db_time
      t.integer :view_time
      t.string :environment
      t.string :release
      t.string :server_name
      t.string :http_method
      t.string :http_status
      t.string :http_url

      # Promoted columns kept as plain columns for fast filtering.
      t.boolean :spans_truncated, default: false, null: false
      t.integer :query_count, default: 0, null: false
      t.boolean :has_n_plus_one, default: false, null: false

      # Tags + measurements stored as plain JSON — small per row, queryable
      # via json_extract, no compression overhead. Stack-trace-bearing
      # payloads (events) stay compressed; transactions don't carry them.
      t.json :tags
      t.json :measurements

      t.timestamps
    end

    add_index :transactions, [:project_id, :transaction_id], unique: true
    add_index :transactions, [:project_id, :timestamp]
    add_index :transactions, :project_id
    add_index :transactions, :timestamp
    add_index :transactions, :transaction_name
    add_index :transactions, :duration
  end
end
