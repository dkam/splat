class AddIngestTogglesToSettings < ActiveRecord::Migration[8.1]
  def change
    # Per-data-type ingest switches on the singleton settings row, enforced at
    # the earliest point (envelope ingest) so disabled items are never queued.
    # Events/transactions default ON (existing behaviour). Logs default OFF:
    # Sentry SDKs only emit logs when explicitly opted in, so storing them is
    # opt-in on the Splat side too (high-volume, newer data type).
    add_column :settings, :store_events, :boolean, default: true, null: false
    add_column :settings, :store_transactions, :boolean, default: true, null: false
    add_column :settings, :store_logs, :boolean, default: false, null: false

    # Logs are the highest-volume, shortest-lived data — keep the default
    # retention short.
    add_column :settings, :logs_data_retention_days, :integer, default: 14, null: false
  end
end
