class OidcAuthController < ApplicationController
  allow_unauthenticated_access only: [:login, :start_oidc, :callback]

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

    # Build authorization URI
    auth_params = {
      scope: "openid email profile",
      response_type: "code",
      state: session[:auth_state],
      redirect_uri: oidc_client.redirect_uri
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

    begin
      # Exchange authorization code for tokens using gem
      oidc_client.authorization_code = params[:code]
      access_token = oidc_client.access_token!

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
      start_new_session_for(user_info)

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
      iat: decoded_jwt['iat']
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
end