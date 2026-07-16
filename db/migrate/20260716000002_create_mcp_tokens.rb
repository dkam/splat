# Per-user MCP bearer tokens. One row per allowlisted email; ENV["MCP_AUTH_TOKEN"]
# stays valid alongside these as the instance/headless token.
#
# The token is stored in the clear, matching projects.public_key — the other
# copy-pasteable credential this app hands out. ActiveRecord encryption isn't
# configured here (no keys in credentials or ENV), and the data an MCP token
# reaches is the same data sitting in these files unencrypted, so a digest would
# buy little and would cost the copy-it-back-later UI this exists for.
class CreateMcpTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :mcp_tokens do |t|
      t.string :user_email, null: false
      t.string :token, null: false
      t.datetime :last_used_at

      t.timestamps
    end

    # user_email unique: one token per person, so "reset" is an update rather
    # than an ever-growing pile of live credentials. token unique + indexed:
    # every MCP request authenticates by looking a token up here.
    add_index :mcp_tokens, :user_email, unique: true
    add_index :mcp_tokens, :token, unique: true
  end
end
