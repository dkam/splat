class AuthController < ApplicationController
  skip_before_action :require_authentication, only: [:login, :callback, :failure, :forward_auth]
  before_action :check_rate_limit, only: [:login, :callback]

  # GET /auth/login - Redirect user to OIDC provider
  def login
    unless oidc_configured?
      redirect_to root_path, alert: "Authentication is not configured. Please contact an administrator."
      return
    end

    # Store return URL for after authentication
    session[:return_to] = params[:return_to] if params[:return_to].present?

    # Generate state for CSRF protection
    session[:auth_state] = SecureRandom.hex(16)
    session[:auth_code_verifier] = PKCE.code_verifier if pkce_required?

    # Build authorization URI
    auth_params = {
      scope: 'openid email profile',
      response_type: 'code',
      state: session[:auth_state],
      redirect_uri: oidc_client.redirect_uri
    }

    # Add PKCE if required
    if pkce_required?
      auth_params[:code_challenge] = PKCE.code_challenge(session[:auth_code_verifier])
      auth_params[:code_challenge_method] = 'S256'
    end

    # Redirect to OIDC provider
    redirect_to oidc_client.authorization_uri(auth_params), allow_other_host: true
  end

  # GET /auth/callback - Handle OIDC provider callback
  def callback
    unless oidc_configured?
      redirect_to root_path, alert: "Authentication not configured."
      return
    end

    # Verify state parameter (CSRF protection)
    state = params[:state]
    expected_state = session.delete(:auth_state)

    if state.blank? || state != expected_state
      Rails.logger.error "OAuth state mismatch: expected #{expected_state}, got #{state}"
      redirect_to root_path, alert: "Invalid authentication request. Please try again."
      return
    end

    # Exchange authorization code for tokens
    begin
      token_params = {
        code: params[:code],
        redirect_uri: oidc_redirect_uri,
        state: state
      }

      # Add PKCE verifier if required
      if pkce_required?
        code_verifier = session.delete(:auth_code_verifier)
        token_params[:code_verifier] = code_verifier
      end

      # Exchange code for access token
      tokens = oidc_client.authorization_code_callback(token_params)

      # Get user information
      user_info = oidc_client.userinfo(tokens.access_token)

      # Process authentication
      handle_authentication(user_info, tokens)

    rescue OpenIDConnect::Exception => e
      Rails.logger.error "OIDC protocol error: #{e.message}"
      redirect_to root_path, alert: "Authentication failed: #{e.message}"
    rescue Rack::OAuth2::Client::Error => e
      Rails.logger.error "OAuth2 client error: #{e.message}"
      redirect_to root_path, alert: "Authentication failed: #{e.message}"
    rescue => e
      Rails.logger.error "OIDC callback error: #{e.message}"
      Rails.logger.error e.backtrace.join("\n") if Rails.env.development?
      redirect_to root_path, alert: "Authentication failed: #{e.message}"
    end
  end

  # GET /auth/failure - Handle authentication failures
  def failure
    error = params[:error] || "Unknown error"
    description = params[:error_description] || "Authentication failed"

    Rails.logger.error "OIDC authentication failure: #{error} - #{description}"

    redirect_to root_path, alert: "Authentication failed: #{description}"
  end

  # GET /auth/forward_auth - ForwardAuth endpoint for reverse proxies
  def forward_auth
    # ForwardAuth is used by reverse proxies (Caddy, Nginx, etc.)
    # to check if a user is authenticated before allowing access

    # Check if user has valid Rails session (from Caddy's ForwardAuth request)
    if authenticated_user?
      # User is authenticated - allow access
      # Provide user context in response headers for Caddy to use
      response.headers['X-Webauth-User'] = current_user_email
      response.headers['X-Webauth-Name'] = current_user_name
      response.headers['X-Webauth-Provider'] = current_user_provider
      response.headers['X-Webauth-Authenticated-At'] = current_user_authenticated_at.iso8601 if current_user_authenticated_at

      head 200  # Allow access - Caddy will read the headers above
    else
      # User not authenticated - deny access
      head 401  # Deny access - Caddy won't receive user headers
    end
  end

  # DELETE /auth/logout - Logout user
  def logout
    # Get user info before clearing
    user_info = TokenEncryptionService.current_user_info(cookies)
    email = user_info&.dig(:email)
    provider = user_info&.dig(:provider)

    # Clear all authentication data comprehensively
    clear_authentication!

    Rails.logger.info "User logged out: #{email} via #{provider}" if email

    redirect_to root_path, notice: "You have been logged out."
  end

  private

  def handle_authentication(user_info, tokens)
    email = user_info.email
    name = user_info.name || user_info.preferred_username || email&.split('@')&.first
    provider = OidcConfig.provider_name

    # Check if user is authorized
    unless SplatAuthorization.authorized?(email)
      Rails.logger.warn "Unauthorized login attempt: #{email} from #{provider}"
      redirect_to root_path, alert: "Access denied. Your email (#{email}) is not authorized to access this application."
      return
    end

    # Create encrypted token from OIDC response
    encrypted_token = EncryptedToken.from_oidc_response(user_info, tokens, provider)

    # Store token in encrypted cookie
    if TokenEncryptionService.store_token(cookies, encrypted_token)
      # Log successful authentication
      Rails.logger.info "User authenticated: #{email} via #{provider} (stored in encrypted cookie)"
    else
      Rails.logger.error "Failed to store encrypted token for #{email}"
      redirect_to root_path, alert: "Authentication succeeded but failed to store session. Please try again."
      return
    end

    # Redirect to intended page or root
    redirect_to session.delete(:return_to) || root_path, notice: "Welcome #{name}!"
  end

  def oidc_client
    @oidc_client ||= build_oidc_client
  end

  def build_oidc_client
    # Get OIDC configuration from discovery URL or individual endpoints
    oidc_config = load_oidc_configuration

    # Create client dynamically per request (better error handling)
    client = OpenIDConnect::Client.new({
      identifier: ENV.fetch('OIDC_CLIENT_ID'),
      secret: ENV.fetch('OIDC_CLIENT_SECRET'),
      authorization_endpoint: oidc_config[:authorization_endpoint],
      token_endpoint: oidc_config[:token_endpoint],
      userinfo_endpoint: oidc_config[:userinfo_endpoint],
      jwks_uri: oidc_config[:jwks_uri],
      redirect_uri: oidc_redirect_uri
    })

    Rails.logger.debug "Created OIDC client for #{ENV['OIDC_PROVIDER_NAME'] || 'OIDC Provider'}"
    client
  rescue => e
    Rails.logger.error "Failed to create OIDC client: #{e.message}"
    raise "OIDC configuration error: #{e.message}"
  end

  def load_oidc_configuration
    if ENV['OIDC_DISCOVERY_URL'].present?
      # Use discovery URL (preferred method)
      config_from_discovery
    else
      # Fall back to individual endpoint configuration
      config_from_env_vars
    end
  rescue => e
    Rails.logger.error "Failed to load OIDC configuration: #{e.message}"
    raise e
  end

  def config_from_discovery
    base_url = ENV.fetch('OIDC_DISCOVERY_URL')
    # Ensure the discovery URL includes the well-known path (using correct OIDC standard with hyphen)
    if base_url.include?('/.well-known/openid_configuration') || base_url.include?('/.well-known/openid-configuration')
      discovery_url = base_url
    else
      discovery_url = "#{base_url.chomp('/')}/.well-known/openid-configuration"
    end
    Rails.logger.info "Loading OIDC configuration from discovery URL: #{discovery_url}"

    uri = URI.parse(discovery_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = 5
    http.read_timeout = 5

    response = http.get(uri.request_uri)

    # Handle HTTP redirects
    if response.is_a?(Net::HTTPRedirection)
      redirect_uri = URI.parse(response['location'])
      Rails.logger.info "Following redirect to: #{redirect_uri}"
      uri = redirect_uri
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 5
      http.read_timeout = 5
      response = http.get(uri.request_uri)
    end

    # Check for successful response
    unless response.is_a?(Net::HTTPSuccess)
      raise "OIDC discovery endpoint returned #{response.code}: #{response.message}"
    end

    discovery_data = JSON.parse(response.body).with_indifferent_access

    {
      authorization_endpoint: discovery_data[:authorization_endpoint],
      token_endpoint: discovery_data[:token_endpoint],
      userinfo_endpoint: discovery_data[:userinfo_endpoint],
      jwks_uri: discovery_data[:jwks_uri]
    }
  rescue JSON::ParserError => e
    Rails.logger.error "Failed to parse OIDC discovery response as JSON: #{e.message}"
    raise "Invalid JSON response from OIDC discovery endpoint: #{e.message}"
  rescue Net::ReadTimeout, Net::OpenTimeout => e
    Rails.logger.error "OIDC discovery request timed out: #{e.message}"
    raise "OIDC discovery endpoint timed out: #{e.message}"
  rescue Net::HTTPError => e
    Rails.logger.error "OIDC discovery HTTP error: #{e.message}"
    raise "OIDC discovery endpoint returned error: #{e.message}"
  end

  def config_from_env_vars
    Rails.logger.info "Loading OIDC configuration from environment variables"

    {
      authorization_endpoint: ENV.fetch('OIDC_AUTH_ENDPOINT'),
      token_endpoint: ENV.fetch('OIDC_TOKEN_ENDPOINT'),
      userinfo_endpoint: ENV.fetch('OIDC_USERINFO_ENDPOINT'),
      jwks_uri: ENV.fetch('OIDC_JWKS_ENDPOINT')
    }
  end

  def oidc_redirect_uri
    "#{ENV.fetch('RAILS_HOST_PROTOCOL', 'http')}://#{ENV.fetch('RAILS_HOST', 'localhost:3000')}/auth/callback"
  end

  def pkce_required?
    # Some providers require PKCE for additional security
    ENV.fetch('OIDC_REQUIRE_PKCE', 'false').downcase == 'true'
  end

  # Check rate limiting for authentication endpoints
  def check_rate_limit
    client_ip = request.remote_ip
    key = "auth_rate_limit:#{client_ip}"

    # Use Rails.cache for rate limiting
    count = Rails.cache.increment(key, 1, expires_in: 1.hour)

    if count > ENV.fetch('AUTH_RATE_LIMIT_HOURLY', '20').to_i
      Rails.logger.warn "Rate limit exceeded for IP: #{client_ip} (#{count} attempts)"
      render json: {
        error: 'Too many authentication attempts. Please try again later.'
      }, status: :too_many_requests
      return false
    end
  end

  # Simple PKCE implementation for providers that require it
  module PKCE
    extend self

    def code_verifier
      # Generate a random 43-128 character string
      SecureRandom.urlsafe_base64(32).tr('=_-', '')[0, 64]
    end

    def code_challenge(verifier)
      # Base64 URL encode the SHA256 hash of the verifier
      Digest::SHA256.base64digest(verifier).tr('+=/', '-_').tr("\n", '')
    end
  end
end