class RenameSettingsForBurstAlerting < ActiveRecord::Migration[8.1]
  def change
    # Burst alerting is alert-only — the auto_ignore_enabled toggle is gone, and
    # the threshold now reads as the burst-alert threshold it always was.
    rename_column :settings, :auto_ignore_threshold, :burst_threshold
    remove_column :settings, :auto_ignore_enabled, :boolean, default: false, null: false
  end
end
