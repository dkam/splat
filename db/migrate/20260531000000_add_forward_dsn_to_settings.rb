class AddForwardDsnToSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :settings, :forward_dsn, :string
  end
end
