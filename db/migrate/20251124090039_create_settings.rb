class CreateSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :settings do |t|
      t.integer :event_payloads_retention_days, null: false, default: 7
      t.integer :events_data_retention_days, null: false, default: 30
      t.integer :transaction_measurements_retention_days, null: false, default: 7
      t.integer :transactions_data_retention_days, null: false, default: 90

      t.timestamps
    end
  end
end
