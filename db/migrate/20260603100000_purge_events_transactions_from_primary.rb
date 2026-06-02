# Events and transactions now live in their own SQLite files
# (storage/<env>_issues_events.sqlite3 and storage/<env>_transactions_spans.sqlite3),
# along with issues and the new spans table. The primary DB only retains
# projects, releases, oidc_sessions, and settings.
#
# This migration:
#   1. drops the now-unused events / transactions / issues tables on primary
#      (issues moved too, even though it shares no name with another DB);
#   2. reworks the settings retention columns to match the new layout —
#      drops the four ducklake_* columns and the obsolete payload/measurement
#      sub-retentions; adds spans_data_retention_days and histograms_retention_days.
class PurgeEventsTransactionsFromPrimary < ActiveRecord::Migration[8.1]
  def up
    # Tables move to the new DBs. Drop the FKs that reference them first
    # so SQLite (no IF EXISTS for FKs) doesn't complain on subsequent runs.
    drop_table :events       if table_exists?(:events)
    drop_table :transactions if table_exists?(:transactions)
    drop_table :issues       if table_exists?(:issues)

    change_table :settings, bulk: true do |t|
      t.remove :ducklake_events_retention_days       if column_exists?(:settings, :ducklake_events_retention_days)
      t.remove :ducklake_transactions_retention_days if column_exists?(:settings, :ducklake_transactions_retention_days)
      t.remove :ducklake_issues_retention_days       if column_exists?(:settings, :ducklake_issues_retention_days)
      t.remove :ducklake_spans_retention_days        if column_exists?(:settings, :ducklake_spans_retention_days)
      t.remove :event_payloads_retention_days        if column_exists?(:settings, :event_payloads_retention_days)
      t.remove :transaction_measurements_retention_days if column_exists?(:settings, :transaction_measurements_retention_days)

      t.integer :spans_data_retention_days, default: 30,  null: false unless column_exists?(:settings, :spans_data_retention_days)
      t.integer :histograms_retention_days, default: 540, null: false unless column_exists?(:settings, :histograms_retention_days)
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "tables and columns recreated by this migration would be empty; restore from a pre-cutover backup if you need them back"
  end
end
