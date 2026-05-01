class OidcAuthController < ApplicationController
  allow_unauthenticated_access only: [:login, :start_oidc, :callback, :backchannel_logout]

  # GET /login - Show login page
  def login
    # If user is authenticated and no special parameters, redirect to dashboard
    if authenticated? && params[:authenticate] != "true"
      redirect_to root_path, notice: "You are already logged in."
      return
    end

    # Always show login page
    unless oidc_configured?
      render "login/index", status: :service_unavailable
      return
    end

    # Show the login page
    render "login/index"
  end

  # GET /login/start - Actually start OIDC flow
  def start_oidc
    unless oidc_configured?
      redirect_to login_path, alert: "Authentication not configured."
      return
    end

    # Store return URL for after authentication
    session[:return_to] = params[:return_to] if params[:return_to].present?

    # Generate state for CSRF protection
    session[:auth_state] = SecureRandom.hex(16)

    # PKCE: generate verifier and S256 challenge (RFC 7636)
    code_verifier = SecureRandom.urlsafe_base64(64).tr("=", "")
    session[:pkce_verifier] = code_verifier
    code_challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(code_verifier), padding: false)

    # Build authorization URI
    auth_params = {
      scope: "openid email profile",
      response_type: "code",
      state: session[:auth_state],
      redirect_uri: oidc_client.redirect_uri,
      code_challenge: code_challenge,
      code_challenge_method: "S256"
    }

    # Redirect to OIDC provider
    redirect_to oidc_client.authorization_uri(auth_params), allow_other_host: true
  end

  # GET /auth/callback - Handle OIDC provider callback
  def callback
    unless oidc_configured?
      redirect_to login_path, alert: "Authentication not configured."
      return
    end

    # Verify state parameter (CSRF protection)
    state = params[:state]
    expected_state = session.delete(:auth_state)

    unless valid_state_token?(state, expected_state)
      Rails.logger.error "OIDC state mismatch: expected #{expected_state}, got #{state}"
      redirect_to login_path, alert: "Invalid authentication state. Please try again."
      return
    end

    code_verifier = session.delete(:pkce_verifier)
    if code_verifier.blank?
      Rails.logger.error "OIDC callback missing PKCE code_verifier in session"
      redirect_to login_path, alert: "Invalid authentication state. Please try again."
      return
    end

    begin
      # Exchange authorization code for tokens using gem
      oidc_client.authorization_code = params[:code]
      access_token = oidc_client.access_token!(code_verifier: code_verifier)

      # Extract user info from ID token only
      id_token = access_token.id_token
      unless id_token.present?
        redirect_to login_path, alert: "No ID token received from provider"
        return
      end

      # Extract claims from ID token
      claims = extract_claims_from_id_token(id_token)
      user_info = {
        email: claims[:email],
        name: claims[:name] || claims[:preferred_username] || claims[:email]&.split("@")&.first,
        provider: ENV.fetch("OIDC_PROVIDER_NAME", "OIDC")
      }

      # Check authorization
      unless authorized_email?(user_info[:email])
        Rails.logger.warn "Unauthorized login attempt: #{user_info[:email]}"
        redirect_to login_path, alert: "Access denied. Your email (#{user_info[:email]}) is not authorized."
        return
      end

      # Create session
      start_new_session_for(user_info, sid: claims[:sid])

      redirect_to session.delete(:return_to) || root_path,
                  notice: "Welcome #{user_info[:name]}!"

    rescue OpenIDConnect::Exception, Rack::OAuth2::Client::Error => e
      Rails.logger.error "OIDC token exchange error: #{e.class.name} - #{e.message}"
      redirect_to login_path, alert: "Authentication failed. Please try again."
    rescue => e
      Rails.logger.error "OIDC callback error: #{e.class.name} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n") if Rails.env.development?
      redirect_to login_path, alert: "Authentication error occurred. Please try again."
    end
  end

  # DELETE /logout - Logout user
  def logout
    email = current_user_email
    terminate_session

    Rails.logger.info "User logged out: #{email}" if email
    redirect_to login_path, notice: "You have been logged out."
  end

  # POST /oidc/logout - Backchannel logout endpoint
  def backchannel_logout
    logout_token = params[:logout_token]

    unless logout_token.present?
      Rails.logger.warn "Backchannel logout missing logout_token"
      render json: { error: "Missing logout_token" }, status: :bad_request
      return
    end

    begin
      # Validate logout token
      claims = validate_logout_token(logout_token)
      return unless claims  # Validation error already rendered

      # Process logout
      sessions_terminated = process_backchannel_logout(claims)

      Rails.logger.info "Backchannel logout processed: sid=#{claims['sid']}, sessions_terminated=#{sessions_terminated}"

      render json: {
        status: "ok",
        sessions_terminated: sessions_terminated
      }

    rescue => e
      Rails.logger.error "Backchannel logout error: #{e.class.name} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n") if Rails.env.development?
      render json: { error: "Internal server error" }, status: :internal_server_error
    end
  end

  private

  def oidc_client
    @oidc_client ||= begin
      # Strip .well-known/openid-configuration if present (discover! adds it automatically)
      issuer_url = ENV.fetch("OIDC_DISCOVERY_URL").sub(%r{/?\.well-known/openid-configuration/?$}, '').chomp('/')

      # Use gem's discovery directly
      discovery = OpenIDConnect::Discovery::Provider::Config.discover!(issuer_url)

      OpenIDConnect::Client.new(
        identifier: ENV.fetch("OIDC_CLIENT_ID"),
        secret: ENV.fetch("OIDC_CLIENT_SECRET"),
        redirect_uri: "#{request.base_url}/auth/callback",
        authorization_endpoint: discovery.authorization_endpoint,
        token_endpoint: discovery.token_endpoint,
        userinfo_endpoint: discovery.userinfo_endpoint
      )
    rescue OpenIDConnect::ValidationFailed, OpenIDConnect::Discovery::DiscoveryFailed => e
      # If discovery fails with validation, try manual fallback
      Rails.logger.warn "OIDC discovery validation failed: #{e.message}. Trying manual fallback."

      config_url = "#{issuer_url}/.well-known/openid-configuration"
      response = Faraday.get(config_url)
      config = JSON.parse(response.body)

      OpenIDConnect::Client.new(
        identifier: ENV.fetch("OIDC_CLIENT_ID"),
        secret: ENV.fetch("OIDC_CLIENT_SECRET"),
        redirect_uri: "#{request.base_url}/auth/callback",
        authorization_endpoint: config['authorization_endpoint'],
        token_endpoint: config['token_endpoint'],
        userinfo_endpoint: config['userinfo_endpoint']
      )
    end
  end

  def valid_state_token?(state, expected_state)
    state.present? && expected_state.present? && state == expected_state
  end

  def extract_claims_from_id_token(id_token)
    # Decode JWT without verification for claim extraction
    decoded_jwt = JWT.decode(id_token, nil, false).first

    {
      email: decoded_jwt['email'],
      name: decoded_jwt['name'],
      preferred_username: decoded_jwt['preferred_username'],
      sub: decoded_jwt['sub'],
      iss: decoded_jwt['iss'],
      aud: decoded_jwt['aud'],
      exp: decoded_jwt['exp'],
      iat: decoded_jwt['iat'],
      sid: decoded_jwt['sid']  # Session ID for backchannel logout
    }
  end

  def authorized_email?(email)
    return false if email.blank?

    # Use existing authorization logic from SplatAuthorization
    SplatAuthorization.authorized?(email)
  end

  def oidc_configured?
    ENV["OIDC_CLIENT_ID"].present? &&
    ENV["OIDC_CLIENT_SECRET"].present? &&
    ENV["OIDC_DISCOVERY_URL"].present?
  end

  # Backchannel logout validation methods
  def validate_logout_token(logout_token)
    # Decode without verification first to extract claims
    unverified = JWT.decode(logout_token, nil, false).first

    # Verify required claims
    required_claims = %w[iss sub aud iat jti events]
    missing = required_claims - unverified.keys
    if missing.any?
      Rails.logger.warn "Backchannel logout missing claims: #{missing.join(', ')}"
      render json: { error: "Missing claims: #{missing.join(', ')}" }, status: :bad_request
      return nil
    end

    # Verify logout event type
    unless unverified.dig('events', 'http://schemas.openid.net/event/backchannel-logout')
      Rails.logger.warn "Backchannel logout invalid event type: #{unverified['events']}"
      render json: { error: "Invalid logout event type" }, status: :bad_request
      return nil
    end

    # Prevent replay attacks
    jti = unverified['jti']
    cache_key = "logout_token:#{jti}"
    if Rails.cache.exist?(cache_key)
      Rails.logger.warn "Backchannel logout replay attempt: jti=#{jti}"
      render json: { error: "Replay attack detected" }, status: :bad_request
      return nil
    end

    # Cache JWT ID to prevent replay (24 hours based on OIDC spec)
    Rails.cache.write(cache_key, true, expires_in: 24.hours)

    # Verify signature using OP's keys
    decoded = verify_logout_token_signature(logout_token, unverified)
    return nil unless decoded

    decoded
  rescue JWT::DecodeError => e
    Rails.logger.error "Backchannel logout JWT decode error: #{e.message}"
    render json: { error: "Invalid logout token format" }, status: :bad_request
    nil
  end

  def verify_logout_token_signature(logout_token, unverified_claims)
    issuer = unverified_claims['iss']
    audience = unverified_claims['aud']

    # Verify issuer and audience match our configuration
    expected_issuer = ENV.fetch('OIDC_ISSUER', extract_issuer_from_discovery)
    expected_audience = ENV.fetch('OIDC_CLIENT_ID')

    if issuer != expected_issuer
      Rails.logger.warn "Backchannel logout invalid issuer: #{issuer} (expected #{expected_issuer})"
      render json: { error: "Invalid issuer" }, status: :bad_request
      return nil
    end

    if Array(audience).none? { |aud| aud == expected_audience }
      Rails.logger.warn "Backchannel logout invalid audience: #{audience} (expected #{expected_audience})"
      render json: { error: "Invalid audience" }, status: :bad_request
      return nil
    end

    # Fetch JWKS and verify signature
    jwks = fetch_jwks
    decoded = JWT.decode(logout_token, nil, true, {
      iss: expected_issuer,
      aud: expected_audience,
      verify_iss: true,
      verify_aud: true,
      verify_iat: true,
      algorithm: 'RS256',
      jwks: jwks
    }).first

    decoded
  rescue JWT::VerificationError => e
    Rails.logger.error "Backchannel logout signature verification failed: #{e.message}"
    render json: { error: "Invalid signature" }, status: :bad_request
    nil
  rescue JWT::ExpiredSignature => e
    Rails.logger.error "Backchannel logout token expired: #{e.message}"
    render json: { error: "Token expired" }, status: :bad_request
    nil
  rescue => e
    Rails.logger.error "Backchannel logout token verification error: #{e.class.name} - #{e.message}"
    render json: { error: "Token verification failed" }, status: :bad_request
    nil
  end

  def fetch_jwks
    @jwks ||= begin
      discovery_url = ENV.fetch('OIDC_DISCOVERY_URL')
      uri = URI.parse(discovery_url)
      discovery_response = Net::HTTP.get(uri)
      discovery = JSON.parse(discovery_response)

      jwks_uri = discovery['jwks_uri']
      unless jwks_uri
        Rails.logger.error "OIDC discovery missing jwks_uri"
        raise "OIDC provider does not support JWKS"
      end

      jwks_response = Net::HTTP.get(URI.parse(jwks_uri))
      jwks_data = JSON.parse(jwks_response)

      JWT::JWK::Set.new(jwks_data['keys'])
    rescue => e
      Rails.logger.error "Failed to fetch JWKS: #{e.message}"
      raise "Unable to fetch JWKS from OIDC provider"
    end
  end

  def extract_issuer_from_discovery
    # Extract issuer from discovery URL if not explicitly configured
    discovery_url = ENV.fetch('OIDC_DISCOVERY_URL')
    discovery_url.sub(%r{/?\.well-known/openid-configuration/?$}, '').chomp('/')
  end

  def process_backchannel_logout(claims)
    terminated_count = 0

    if claims['sid']
      # Terminate specific session by session ID
      oidc_sessions = [OidcSession.find_by_oidc_sid(claims['sid'])].compact
    else
      # If no sid, terminate all sessions for this user (by subject)
      # This is less common but supported by the spec
      oidc_sessions = OidcSession.find_by_user_email(current_user_email_for_sub(claims['sub']))
    end

    oidc_sessions.each do |oidc_session|
      # Invalidate the session by updating its expiration
      oidc_session.invalidate!
      terminated_count += 1

      Rails.logger.info "Invalidated OIDC session: sid=#{oidc_session.oidc_sid}, email=#{oidc_session.user_email}"
    end

    terminated_count
  end

  def current_user_email_for_sub(sub)
    # Try to map sub to user email
    # This is a simple implementation - in practice you might need a mapping
    # or could use the 'sub' claim directly if you store it
    nil  # For now, we'll rely on 'sid' being present
  end
end