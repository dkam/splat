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

  # The token for an email, minted on first use. Callers are responsible for
  # having checked the email is allowed — this does not gate on the allowlist,
  # because the settings page only ever asks for the logged-in user's own token.
  def self.for(user_email)
    email = normalize(user_email)
    find_by(user_email: email) || create!(user_email: email)
  end

  def self.normalize(user_email)
    user_email.to_s.downcase.strip
  end

  # Authenticate a presented bearer token. Returns the record only if its owner
  # is still allowed in, so allowlist changes take effect without a deploy.
  def self.authenticate(presented)
    return nil if presented.blank?

    record = find_by(token: presented)
    return nil unless record
    return nil unless SplatAuthorization.authorized?(record.user_email)

    record.touch_last_used!
    record
  end

  def reset!
    update!(token: SecureRandom.hex(32))
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
