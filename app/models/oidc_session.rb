class OidcSession < ApplicationRecord
  validates :oidc_sid, presence: true, uniqueness: true
  validates :session_id, presence: true
  validates :user_email, presence: true
  validates :expires_at, presence: true

  # Clean up expired sessions
  def self.cleanup_expired
    where("expires_at < ?", Time.current).delete_all
  end

  # Find session by OIDC session ID
  def self.find_by_oidc_sid(sid)
    where(oidc_sid: sid).where("expires_at > ?", Time.current).first
  end

  # Find all sessions for a user
  def self.find_by_user_email(email)
    where(user_email: email).where("expires_at > ?", Time.current)
  end

  # Invalidate a session (mark for cleanup)
  def invalidate!
    update!(expires_at: 1.minute.ago)
  end

  # Create session mapping for user
  def self.create_for_user(oidc_sid:, session_id:, user_email:, expires_in: 24.hours)
    create!(
      oidc_sid: oidc_sid,
      session_id: session_id,
      user_email: user_email,
      expires_at: expires_in.from_now
    )
  rescue ActiveRecord::RecordNotUnique
    # Handle race condition - session already exists
    Rails.logger.warn "OIDC session already exists for sid: #{oidc_sid}"
    find_by(oidc_sid: oidc_sid)
  end
end
