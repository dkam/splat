class AddNtfyToSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :settings, :ntfy_url, :string
    add_column :settings, :ntfy_token, :string
    add_column :settings, :ntfy_priority, :string, default: "default", null: false
  end
end
