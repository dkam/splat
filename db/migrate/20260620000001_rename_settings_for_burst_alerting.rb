# Burst alerting is alert-only — the auto_ignore_enabled toggle is gone, and the
# threshold now reads as the burst-alert threshold it always was.
#
# The columns this was written against (settings.auto_ignore_threshold and
# auto_ignore_enabled) came from migrations that the sqlite-everything merge
# deleted from db/migrate, so they no longer exist on a from-zero migrate and the
# bare rename aborted. Every step is guarded because there are three live states:
# databases migrated before that merge have auto_ignore_threshold and take the
# rename; databases built from schema.rb since have burst_threshold already;
# a from-zero migrate has neither and needs the column added outright.
class RenameSettingsForBurstAlerting < ActiveRecord::Migration[8.1]
  def up
    if column_exists?(:settings, :auto_ignore_threshold)
      rename_column :settings, :auto_ignore_threshold, :burst_threshold
    elsif !column_exists?(:settings, :burst_threshold)
      add_column :settings, :burst_threshold, :integer, default: 1000, null: false
    end

    remove_column :settings, :auto_ignore_enabled if column_exists?(:settings, :auto_ignore_enabled)
  end

  def down
    rename_column :settings, :burst_threshold, :auto_ignore_threshold if column_exists?(:settings, :burst_threshold)

    unless column_exists?(:settings, :auto_ignore_enabled)
      add_column :settings, :auto_ignore_enabled, :boolean, default: false, null: false
    end
  end
end
