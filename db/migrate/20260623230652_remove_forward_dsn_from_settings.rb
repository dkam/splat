class RemoveForwardDsnFromSettings < ActiveRecord::Migration[8.1]
  def change
    # Global single-target forwarding is replaced by per-project forward_dsns.
    remove_column :settings, :forward_dsn, :string
  end
end
