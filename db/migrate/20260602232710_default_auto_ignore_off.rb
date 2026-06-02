class DefaultAutoIgnoreOff < ActiveRecord::Migration[8.1]
  def change
    change_column_default :settings, :auto_ignore_enabled, from: true, to: false
    Setting.where(auto_ignore_enabled: true).update_all(auto_ignore_enabled: false)
  end
end
