# MCP token lifespan tied to web-session lifespan (per-user tokens only).
#
# last_authenticated_at is stamped when a token is minted and refreshed whenever
# its owner uses the web UI with a valid OIDC session. A per-user token is
# accepted only while that stamp is within mcp_token_ttl_days — so an operator
# who loses OIDC access loses MCP on the same footing they lose the web UI.
#
# ttl default 7: renewal is any web visit, so a week means "look at Splat weekly
# and your agent never notices; disappear for a week and it dies". 0 = never
# expire, for anyone who wants tokens gated only by the allowlist.
class AddMcpTokenExpiry < ActiveRecord::Migration[8.1]
  def change
    add_column :mcp_tokens, :last_authenticated_at, :datetime
    add_column :settings, :mcp_token_ttl_days, :integer, default: 7, null: false
  end
end
