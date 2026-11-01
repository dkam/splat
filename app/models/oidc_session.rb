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

  # Create session mapping for user, or take over the sid's old one. The
  # provider keeps one sid for as long as you're signed in there, so a login
  # after this mapping expired, or after a backchannel logout invalidated it,
  # brings the same sid back — and it has just come with a verified ID token,
  # so the provider holds it live. A second row would fail uniqueness and
  # leave the login untracked, which logs you straight back out.
  def self.create_for_user(oidc_sid:, session_id:, user_email:, expires_in: 24.hours)
    mapping = find_or_initialize_by(oidc_sid: oidc_sid)
    mapping.update!(session_id: session_id, user_email: user_email, expires_at: expires_in.from_now)
    mapping
  rescue ActiveRecord::RecordNotUnique
    # A concurrent login for the same sid inserted first; take its row over.
    retry
  end
end
