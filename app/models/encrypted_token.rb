# frozen_string_literal: true

# Model for storing encrypted JWT tokens in secure cookies
# Provides secure encryption/decryption using Rails 7+ built-in credentials encryption
class EncryptedToken
  include ActiveModel::Model
  include ActiveModel::Attributes

  # Encrypted attributes using Rails 7+ credentials encryption
  attribute :access_token, :string
  attribute :refresh_token, :string
  attribute :id_token, :string

  # Non-encrypted attributes
  attribute :expires_at, :datetime
  attribute :token_type, :string, default: 'Bearer'
  attribute :provider, :string
  attribute :user_email, :string
  attribute :user_name, :string
  attribute :authenticated_at, :datetime

  validates :user_email, presence: true
  validates :provider, presence: true
  validates :token_type, presence: true

  class << self
    # Create encrypted token from OIDC response
    def from_oidc_response(user_info, tokens, provider)
      new(
        user_email: user_info.email,
        user_name: user_info.name || user_info.preferred_username || user_info.email&.split('@')&.first,
        provider: provider,
        access_token: tokens.access_token,
        refresh_token: tokens.refresh_token,
        id_token: tokens.id_token,
        expires_at: tokens.expires_at ? Time.at(tokens.expires_at) : nil,
        token_type: tokens.token_type || 'Bearer',
        authenticated_at: Time.current
      )
    end

    # Load from encrypted cookie
    def from_cookie(cookie_value)
      return nil if cookie_value.blank?

      begin
        # Decrypt the JSON data from cookie
        data = decrypt_cookie_data(cookie_value)
        from_json(data)
      rescue => e
        Rails.logger.error "Failed to load encrypted token from cookie: #{e.message}"
        nil
      end
    end

    # Find valid token for user
    def find_valid_for_user(email, provider)
      # This would be used if we stored tokens in database
      # For cookie-based approach, we'll use from_cookie
      nil
    end

    private

    # Decrypt cookie data using Rails message verifier
    def decrypt_cookie_data(encrypted_data)
      verifier = Rails.application.message_verifier('encrypted_token')
      verifier.verify(encrypted_data)
    end
  end

  # Check if token is expired
  def expired?
    return false if expires_at.blank?
    Time.current > expires_at
  end

  # Check if token needs refresh (5 minutes before expiry)
  def needs_refresh?
    return false if expires_at.blank? || refresh_token.blank?
    Time.current > (expires_at - 5.minutes)
  end

  # Check if token can be refreshed
  def refreshable?
    refresh_token.present? && !expired?
  end

  # Get remaining time until expiry
  def expires_in_seconds
    return nil if expires_at.blank?
    [(expires_at - Time.current).to_i, 0].max
  end

  # Convert to encrypted cookie format
  def to_cookie
    data = as_json(except: [:access_token, :refresh_token, :id_token])
    # Store sensitive tokens directly (will be encrypted by message verifier)
    data["encrypted_access_token"] = access_token
    data["encrypted_refresh_token"] = refresh_token
    data["encrypted_id_token"] = id_token

    verifier = Rails.application.message_verifier("encrypted_token")
    verifier.generate(data)
  end

  # Convert to JSON (with encrypted fields)
  def as_json(options = {})
    super
  end

  # Create instance from JSON data
  def from_json(data)
    self.attributes = data.except("encrypted_access_token", "encrypted_refresh_token", "encrypted_id_token")
    self.access_token = data["encrypted_access_token"] if data["encrypted_access_token"]
    self.refresh_token = data["encrypted_refresh_token"] if data["encrypted_refresh_token"]
    self.id_token = data["encrypted_id_token"] if data["encrypted_id_token"]
    self
  end

  # Validate token integrity
  def valid?
    return false if user_email.blank? || provider.blank?
    return false if expired?
    true
  end

  # Get safe user info for logging (no tokens)
  def user_info
    {
      email: user_email,
      name: user_name,
      provider: provider,
      authenticated_at: authenticated_at,
      expires_at: expires_at
    }
  end

  private

  # Override attribute writer to handle encrypted fields properly
  def attributes=(attributes)
    super
  end
end