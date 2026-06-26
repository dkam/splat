class AddForwardDsnsToProjects < ActiveRecord::Migration[8.1]
  def change
    # One or more downstream DSNs to forward this project's envelopes to.
    # Stored as a JSON array of DSN strings; empty array = no forwarding.
    add_column :projects, :forward_dsns, :json, default: []
  end
end
