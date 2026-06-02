class AddAutoIgnoreFields < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :auto_ignored_at, :datetime
    add_column :issues, :auto_ignore_rate, :integer

    add_column :settings, :auto_ignore_enabled, :boolean, null: false, default: true
    add_column :settings, :auto_ignore_threshold, :integer, null: false, default: 1000
  end
end
