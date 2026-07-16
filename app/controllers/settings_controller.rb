class SettingsController < ApplicationController
  before_action :set_setting, only: [:update]

  def index
    @setting = Setting.instance

    # Read the precomputed snapshot — never run the dbstat scan inline (it
    # walks every page of each DB file and can take tens of seconds). On a
    # cold cache (fresh deploy) the snapshot is nil; show a pending state and
    # enqueue a build so the next view has it. The 15m scheduled job keeps it
    # fresh thereafter.
    @storage = StorageStats.snapshot
    StorageStats.enqueue_refresh if @storage.nil?

    # Queue depths are live (tuber stats are in-memory and cheap) — unlike the
    # dbstat snapshot, no point caching them. Degrades to {} if tuber is down.
    @queues = Ingest::Tuber.queue_depths

    @mcp_token = mcp_token_for_current_user
  end

  def reset_mcp_token
    token = mcp_token_for_current_user

    if token.nil?
      redirect_to settings_path, alert: "Sign in to manage your MCP token."
      return
    end

    token.reset!
    redirect_to settings_path, notice: "MCP token reset. Update any client using the old token."
  end

  def update
    if @setting.update(setting_params)
      redirect_to settings_path, notice: "Settings updated successfully."
    else
      redirect_to settings_path, alert: "Error updating settings: #{@setting.errors.full_messages.join(", ")}"
    end
  end

  private

  # Nil unless there's a signed-in, still-allowlisted user to mint a token for.
  #
  # This is the gate that keeps the token off a public page: require_authentication
  # is a no-op when OIDC isn't configured, so on such an instance the settings
  # page is world-readable and authenticated? is false — nothing is rendered and
  # no row is created. Those instances use ENV["MCP_AUTH_TOKEN"] instead.
  #
  # The allowlist is re-checked rather than trusted from the session, which may
  # predate an SPLAT_ALLOWED_USERS change.
  def mcp_token_for_current_user
    return nil unless authenticated?
    return nil unless SplatAuthorization.authorized?(current_user_email)

    McpToken.for(current_user_email)
  end

  def set_setting
    @setting = Setting.instance
  end

  def setting_params
    params.require(:setting).permit(
      :events_data_retention_days,
      :transactions_data_retention_days,
      :spans_data_retention_days,
      :logs_data_retention_days,
      :histograms_retention_days,
      :store_events,
      :store_transactions,
      :store_logs,
      :burst_threshold,
      :ntfy_url,
      :ntfy_token,
      :ntfy_priority
    )
  end
end
