class AddBurstColumnsToIssues < ActiveRecord::Migration[8.1]
  def change
    # Persisted burst state for the alert UI (badge/banner) and to survive
    # cache eviction. Set by Issue#maybe_alert_burst! when an open issue crosses
    # the events/hour threshold. Alert-only — no auto-ignore.
    add_column :issues, :last_burst_at, :datetime
    add_column :issues, :last_burst_rate, :integer
  end
end
