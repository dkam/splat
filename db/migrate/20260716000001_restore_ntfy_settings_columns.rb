# settings.ntfy_url / ntfy_token / ntfy_priority are in schema.rb and are read by
# the ntfy notification path, but the migration that added them (20260602231708)
# was deleted from db/migrate by the sqlite-everything merge, leaving the columns
# with nothing to create them on a from-zero migrate.
#
# Guarded, so this only does work where the columns are actually missing:
# databases migrated before the merge, and databases built from schema.rb since,
# both already have them and no-op here.
class RestoreNtfySettingsColumns < ActiveRecord::Migration[8.1]
  def change
    add_column :settings, :ntfy_url, :string unless column_exists?(:settings, :ntfy_url)
    add_column :settings, :ntfy_token, :string unless column_exists?(:settings, :ntfy_token)

    unless column_exists?(:settings, :ntfy_priority)
      add_column :settings, :ntfy_priority, :string, default: "default", null: false
    end
  end
end
