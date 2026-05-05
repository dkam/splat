class AddDucklakeRetentionToSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :settings, :ducklake_events_retention_days, :integer, null: false, default: 365
    add_column :settings, :ducklake_transactions_retention_days, :integer, null: false, default: 365
    add_column :settings, :ducklake_issues_retention_days, :integer, null: false, default: 730
  end
end
