class CreateTransactions < ActiveRecord::Migration[8.1]
  def change
    create_table :transactions do |t|
      t.references :project, null: false, foreign_key: true
      t.string :transaction_id, null: false
      t.datetime :timestamp, null: false
      t.string :transaction_name, null: false
      t.string :op

      # Timings (milliseconds)
      t.integer :duration, null: false
      t.integer :db_time
      t.integer :view_time

      # Context
      t.string :environment
      t.string :release
      t.string :server_name

      # HTTP specifics (if applicable)
      t.string :http_method
      t.string :http_status
      t.string :http_url

      # Lightweight payload for details
      t.json :tags
      t.json :measurements

      t.timestamps
    end

    # Essential indexes only
    add_index :transactions, [:project_id, :transaction_id], unique: true
    add_index :transactions, :timestamp
    add_index :transactions, :transaction_name
    add_index :transactions, :duration
  end
end

    add_index :transactions, :transaction_id, unique: true
    add_index :transactions, :timestamp
    add_index :transactions, :transaction_name
    add_index :transactions, :duration
    add_index :transactions, [ :transaction_name, :timestamp ]
    add_index :transactions, [ :environment, :timestamp ]
    add_index :transactions, :http_status
    add_index :transactions, :http_method
  end
end
