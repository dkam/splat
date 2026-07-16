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

    # Exactly one of these is ever set — see #mcp_token_for_current_user.
    @mcp_token = mcp_token_for_current_user
    @instance_mcp_token = @setting.mcp_token! if instance_mcp_token?
  end

  def reset_mcp_token
    if instance_mcp_token?
      Setting.instance.reset_mcp_token!
    else
      token = mcp_token_for_current_user

      # require_authentication has already bounced anonymous visitors to /login,
      # so the only way here is signed in but no longer on the allowlist.
      if token.nil?
        redirect_to settings_path, alert: "Your address isn't on the allowlist, so you have no MCP token."
        return
      end

      token.reset!
    end

    redirect_to settings_path, notice: "MCP token regenerated. Update any client using the old one."
  end

  def update
    if @setting.update(setting_params)
      redirect_to settings_path, notice: "Settings updated successfully."
    else
      redirect_to settings_path, alert: "Error updating settings: #{@setting.errors.full_messages.join(", ")}"
    end
  end

  private

  # No OIDC means no users, so /mcp authenticates with one shared instance token
  # and that's what the panel offers.
  #
  # Showing a credential on a page with no sign-in is deliberate here: without
  # OIDC this page already hands anyone who can reach it the Resolve and Ignore
  # buttons, so the token grants strictly less than the page around it. Such
  # deployments are expected to be guarded at the network or proxy (see the
  # README's basic-auth recipe), which protects this panel along with the rest.
  def instance_mcp_token?
    !SplatAuthorization.oidc_configured?
  end

  # Nil unless there's a signed-in, still-allowlisted user to mint a token for.
  # Only consulted when OIDC is on, where require_authentication guarantees a
  # session — so a token is never rendered to an anonymous visitor of an
  # OIDC-protected instance.
  #
  # The allowlist is re-checked rather than trusted from the session, which may
  # predate an SPLAT_ALLOWED_USERS change.
  def mcp_token_for_current_user
    return nil if instance_mcp_token?
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
      :mcp_token_ttl_days,
      :ntfy_url,
      :ntfy_token,
      :ntfy_priority
    )
  end
end
