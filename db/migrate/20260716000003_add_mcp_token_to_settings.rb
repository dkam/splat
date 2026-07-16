# The instance MCP token, for a Splat with no OIDC and therefore no users to
# scope a token to. Lives on the settings singleton because that's exactly what
# it is: one credential for the whole instance.
#
# Distinct from ENV["MCP_AUTH_TOKEN"], which stays valid in every configuration
# as the headless escape hatch (cron, CI) — an env var can't be regenerated from
# a web page, which is the whole reason this column exists.
#
# Nullable: minted lazily the first time the settings page is opened, so an
# instance that never uses MCP never carries a live credential.
class AddMcpTokenToSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :settings, :mcp_token, :string
    add_column :settings, :mcp_token_last_used_at, :datetime
  end
end
