class CreateSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :settings do |t|
      t.integer :payload_retention_days, null: false, default: 1
      t.integer :events_stats_retention_days, null: false, default: 90
      t.integer :transactions_stats_retention_days, null: false, default: 30
      t.integer :duckdb_migration_batch_size, null: false, default: 1000
      t.boolean :enable_duckdb_migration, null: false, default: true

      t.timestamps
    end
  end
end
