# frozen_string_literal: true

# A per-user bearer token for the MCP endpoint.
#
# Splat has no users table — SplatAuthorization's email/domain allowlist is the
# source of truth for who may in. So a token is keyed by email and carries no
# association: authorisation is re-checked against the allowlist on every
# request (see Mcp::McpController#valid_mcp_token?), which means removing
# someone from SPLAT_ALLOWED_USERS/SPLAT_ALLOWED_DOMAINS revokes their token
# immediately, with no row to delete and no orphan left behind.
class McpToken < ApplicationRecord
  validates :user_email, presence: true, uniqueness: true
  validates :token, presence: true, uniqueness: true

  before_validation :generate_token, if: -> { token.blank? }

  # last_used_at is display-only, so it isn't worth a write per request on a
  # chatty MCP client. Coarse enough to answer "is this token still in use?".
  TOUCH_AFTER = 5.minutes

  # How stale last_authenticated_at may get before a web visit rewrites it.
  # Only needs to be small relative to the shortest useful TTL (1 day), not
  # per-request — it exists to keep chatty browsing from writing every request.
  AUTH_REFRESH_AFTER = 1.hour

  # The token for an email, minted on first use. Callers are responsible for
  # having checked the email is allowed — this does not gate on the allowlist,
  # because the settings page only ever asks for the logged-in user's own token.
  #
  # Reaching this means the caller is authenticated right now (they're viewing
  # their own settings), so it doubles as a renewal point: touch_authenticated!
  # stamps a fresh row and refreshes an existing one.
  def self.for(user_email)
    email = normalize(user_email)
    token = find_by(user_email: email) || create!(user_email: email)
    token.touch_authenticated!
    token
  end

  def self.normalize(user_email)
    user_email.to_s.downcase.strip
  end

  # Authenticate a presented bearer token. Returns:
  #   the record  — valid
  #   :expired    — real, allowlisted, but its owner hasn't used the web UI
  #                 within mcp_token_ttl_days (caller can point them at renewal)
  #   nil         — unknown token or off-allowlist (say nothing specific)
  def self.authenticate(presented)
    return nil if presented.blank?

    record = find_by(token: presented)
    return nil unless record
    return nil unless SplatAuthorization.authorized?(record.user_email)
    return :expired if record.authentication_expired?

    record.touch_last_used!
    record
  end

  def reset!
    update!(token: SecureRandom.hex(32))
  end

  # Tokens track their owner's web-session life: valid only while they've signed
  # in within the configured window. ttl 0 disables this, leaving the allowlist
  # as the only gate. A token that has somehow never been stamped is treated as
  # expired rather than eternal.
  def authentication_expired?
    ttl = Setting.instance.mcp_token_ttl_days
    return false if ttl.to_i.zero?
    return true if last_authenticated_at.nil?

    last_authenticated_at < ttl.days.ago
  end

  # Renew, called from any authenticated web request (see ApplicationController).
  # Throttled: a fresh stamp isn't rewritten on every page load.
  def touch_authenticated!
    return if last_authenticated_at.present? && last_authenticated_at > AUTH_REFRESH_AFTER.ago

    update_column(:last_authenticated_at, Time.current)
  end

  # Immediate revocation, called when the owner's OIDC session is killed by a
  # backchannel logout — the token dies on its next call rather than waiting out
  # the TTL. Distinct from a session merely lapsing, which the TTL window covers.
  def expire_authentication!
    update_column(:last_authenticated_at, nil)
  end

  def touch_last_used!
    return if last_used_at.present? && last_used_at > TOUCH_AFTER.ago

    # update_column: no validations, no updated_at churn on a read path.
    update_column(:last_used_at, Time.current)
  end

  private

  def generate_token
    self.token = SecureRandom.hex(32)
  end
end
