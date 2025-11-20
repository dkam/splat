# frozen_string_literal: true

# Service for handling encrypted token operations in cookies
# Provides secure storage and retrieval of JWT tokens using Rails message verifier
class TokenEncryptionService
  COOKIE_NAME = 'splat_auth_token'.freeze

  class << self
    # Store encrypted token in cookie
    def store_token(cookies, encrypted_token)
      return false unless encrypted_token&.valid?

      begin
        cookie_value = encrypted_token.to_cookie
        validate_cookie_size(cookie_value)
        cookies[COOKIE_NAME] = { value: cookie_value, **cookie_options }
        Rails.logger.info "Stored encrypted token for #{encrypted_token.user_email}"
        true
      rescue => e
        Rails.logger.error "Failed to store encrypted token: #{e.class.name}"
        false
      end
    end

    # Retrieve and decrypt token from cookie
    def retrieve_token(cookies)
      cookie_value = cookies[COOKIE_NAME]
      return nil if cookie_value.blank?

      Rails.logger.debug "Attempting to load encrypted token from cookie (size: #{cookie_value.bytesize} bytes)"
      encrypted_token = EncryptedToken.from_cookie(cookie_value)
      Rails.logger.debug "EncryptedToken.from_cookie returned: #{encrypted_token&.class&.name}"

      if encrypted_token
        Rails.logger.debug "Token email: #{encrypted_token.user_email}, valid?: #{encrypted_token.valid?}"
        Rails.logger.debug "Token expires_at: #{encrypted_token.expires_at}, expired?: #{encrypted_token.expired?}"
      end

      return encrypted_token unless encrypted_token&.valid?

      # Verify JWT signature if configured
      if jwt_verification_enabled?
        unless JwtVerificationService.verify_access_token(encrypted_token.access_token)
          Rails.logger.warn "JWT signature verification failed for token"
          return nil
        end
      end

      encrypted_token
    end

    # Clear token from cookies
    def clear_token(cookies)
      cookies.delete COOKIE_NAME, { domain: :all }
      Rails.logger.info "Cleared encrypted token cookie"
    end

    # Check if token exists and is valid
    def valid_token?(cookies)
      token = retrieve_token(cookies)
      token&.valid?
    end

    # Check if token needs refresh
    def token_needs_refresh?(cookies)
      token = retrieve_token(cookies)
      token&.needs_refresh? || false
    end

    # Refresh access token using refresh token
    def refresh_access_token(cookies, oidc_client)
      encrypted_token = retrieve_token(cookies)
      return false unless encrypted_token&.refreshable?

      begin
        # Use refresh token to get new access token
        token_response = oidc_client.refresh_token(encrypted_token.refresh_token)

        # Update token with new values
        encrypted_token.access_token = token_response.access_token
        encrypted_token.refresh_token = token_response.refresh_token if token_response.refresh_token
        encrypted_token.expires_at = token_response.expires_at ? Time.at(token_response.expires_at) : nil

        # Store updated token
        store_token(cookies, encrypted_token)

        Rails.logger.info "Successfully refreshed token for #{encrypted_token.user_email}"
        true
      rescue => e
        Rails.logger.error "Failed to refresh access token: #{e.message}"
        # If refresh fails, clear the token
        clear_token(cookies)
        false
      end
    end

    # Get current user info from token
    def current_user_info(cookies)
      token = retrieve_token(cookies)
      return nil unless token&.valid?

      {
        email: token.user_email,
        name: token.user_name,
        provider: token.provider,
        authenticated_at: token.authenticated_at,
        expires_at: token.expires_at
      }
    end

    # Check if user is authenticated via encrypted token
    def authenticated?(cookies)
      valid_token?(cookies)
    end

    # Extract access token for API calls
    def access_token(cookies)
      token = retrieve_token(cookies)
      token&.access_token
    end

    # Extract refresh token for token refresh
    def refresh_token(cookies)
      token = retrieve_token(cookies)
      token&.refresh_token
    end

    # Update token expiry
    def update_token_expiry(cookies, new_expires_at)
      token = retrieve_token(cookies)
      return false unless token

      token.expires_at = new_expires_at
      store_token(cookies, token)
    end

    # Migrate from session to encrypted cookie
    def migrate_from_session(session, cookies)
      return false if valid_token?(cookies) # Already have valid token

      email = session[:user_email]
      return false if email.blank? # No session to migrate

      begin
        # Create encrypted token from session data
        encrypted_token = EncryptedToken.new(
          user_email: email,
          user_name: session[:user_name],
          provider: session[:provider],
          access_token: session[:access_token],
          refresh_token: session[:refresh_token],
          expires_at: session[:expires_at] ? Time.at(session[:expires_at]) : nil,
          token_type: 'Bearer',
          authenticated_at: session[:authenticated_at] || Time.current
        )

        if encrypted_token.valid?
          success = store_token(cookies, encrypted_token)
          if success
            # Clear session data after successful migration
            session_keys = [:user_email, :user_name, :provider, :access_token, :refresh_token, :expires_at, :authenticated_at]
            session_keys.each { |key| session.delete(key) }
            Rails.logger.info "Successfully migrated authentication from session to encrypted cookie"
          end
          success
        else
          false
        end
      rescue => e
        Rails.logger.error "Failed to migrate from session: #{e.message}"
        false
      end
    end

    private

    # Check if JWT verification is enabled
    def jwt_verification_enabled?
      return true if Rails.env.production?
      ENV.fetch('OIDC_VERIFY_JWT_SIGNATURE', 'false').downcase == 'true'
    end

    # Get cookie options with dynamic expiry
    def cookie_options
      {
        httponly: true,
        secure: !Rails.env.development?,
        same_site: :strict,
        expires: cookie_expiry_time,
        path: "/",
        domain: ENV.fetch("COOKIE_DOMAIN", :all)
      }
    end

    # Get cookie expiry time from environment
    def cookie_expiry_time
      hours = ENV.fetch('COOKIE_EXPIRY_HOURS', '24').to_i
      hours.hours.from_now
    end

    # Monitor cookie size and warn if too large
    def validate_cookie_size(cookie_value)
      size = cookie_value.bytesize
      if size > 3500
        Rails.logger.warn "Large authentication cookie: #{size} bytes (limit: 4096)"
      end
      size
    end
  end
end