class AuthController < ApplicationController
  skip_before_action :require_authentication, only: [:login, :callback, :failure, :forward_auth]
  # before_action :check_rate_limit, only: [:login, :callback]

  # GET /auth/login - Redirect user to OIDC provider
  def login
    unless oidc_configured?
      render plain: "Authentication is not configured. Please contact an administrator.", status: :service_unavailable
      return
    end

    # Store return URL for after authentication
    session[:return_to] = params[:return_to] if params[:return_to].present?

    # Generate state for CSRF protection
    session[:auth_state] = SecureRandom.hex(16)
    session[:auth_code_verifier] = PKCE.code_verifier if pkce_required?

    # Build authorization URI
    auth_params = {
      scope: "openid email profile",
      response_type: "code",
      state: session[:auth_state],
      redirect_uri: oidc_client.redirect_uri
    }

    # Add PKCE if required
    if pkce_required?
      auth_params[:code_challenge] = PKCE.code_challenge(session[:auth_code_verifier])
      auth_params[:code_challenge_method] = "S256"
    end
    Rails.logger.info("About to redurect")

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

    Rails.logger.debug "OAuth state: received=#{state}, expected=#{expected_state}"

    if state.blank? || state != expected_state
      Rails.logger.error "OAuth state mismatch: expected #{expected_state}, got #{state}"
      redirect_to root_path, alert: "Invalid authentication request. Please try again."
      return
    end

    # Check if we already have a code (possible double submission or expired code)
    if session[:auth_code_used]
      Rails.logger.warn "Authorization code already used for state: #{expected_state} - starting fresh authentication"
      session.delete(:auth_code_used)  # Clear the flag
      session.delete(:auth_state)      # Clear the old state
      redirect_to auth_login_path, notice: "Authentication session expired. Please try again."
      return
    end

    # Mark this code as used to prevent double submission
    session[:auth_code_used] = true

    # Exchange authorization code for tokens
    begin
      auth_code = params[:code]
      Rails.logger.debug "Authorization code: #{auth_code&.first(10)}..."

      # Use the OpenIDConnect gem's built-in token exchange
      begin
        # Build token request parameters
        token_params = {
          "grant_type" => "authorization_code",
          "code" => auth_code,
          "redirect_uri" => oidc_redirect_uri,
          "client_id" => ENV.fetch("OIDC_CLIENT_ID"),
          "client_secret" => ENV.fetch("OIDC_CLIENT_SECRET")
        }

        # Add PKCE verifier if required
        if pkce_required?
          code_verifier = session.delete(:auth_code_verifier)
          if code_verifier
            token_params["code_verifier"] = code_verifier
            Rails.logger.debug "PKCE verifier added: #{code_verifier.present?}"
          else
            Rails.logger.error "PKCE required but no code_verifier found in session"
            redirect_to auth_login_path, alert: "Authentication session expired. Please try again."
            return
          end
        end

        # Make token request directly to avoid gem issues
        uri = URI.parse(oidc_client.token_endpoint)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 10
        http.read_timeout = 10

        request = Net::HTTP::Post.new(uri.request_uri)
        request.set_form_data(token_params)
        request["Content-Type"] = "application/x-www-form-urlencoded"
        request["Accept"] = "application/json"

        response = http.request(request)

        unless response.is_a?(Net::HTTPSuccess)
          error_body = response.body
          Rails.logger.error "Token request failed: #{response.code} #{response.message} - #{error_body}"

          # Handle common OAuth errors
          if response.code == "400" && error_body.include?("invalid_grant")
            redirect_to auth_login_path, notice: "Authentication session expired. Please try again."
          else
            redirect_to auth_login_path, alert: "Token exchange failed: #{error_body}"
          end
          return
        end

        token_data = JSON.parse(response.body)

        # Create access token object from response
        client = OpenIDConnect::Client.new(
          identifier: ENV.fetch("OIDC_CLIENT_ID"),
          secret: ENV.fetch("OIDC_CLIENT_SECRET"),
          authorization_endpoint: oidc_client.authorization_endpoint,
          token_endpoint: oidc_client.token_endpoint,
          userinfo_endpoint: oidc_client.userinfo_endpoint,
          redirect_uri: oidc_redirect_uri
        )

        # Create an access token from the response
        access_token = OpenIDConnect::AccessToken.new(
          client: client,
          access_token: token_data["access_token"],
          refresh_token: token_data["refresh_token"],
          expires_in: token_data["expires_in"],
          id_token: token_data["id_token"]
        )

        tokens = access_token
        Rails.logger.debug "Token exchange successful via manual request"
      rescue => e
        # Check if this is an OAuth protocol error (used/invalid codes)
        error_message = e.message.to_s.downcase
        if error_message.include?('invalid_grant') ||
           error_message.include?('code') && error_message.include?('used') ||
           error_message.include?('expired') ||
           error_message.include?('authorization_code')
          Rails.logger.error "OAuth token exchange error (used/invalid code): #{e.message}"
          Rails.logger.info "Redirecting to fresh login due to token exchange failure"
          redirect_to auth_login_path, notice: "Authentication session expired. Please try again."
          return
        else
          Rails.logger.error "Token exchange failed via gem: #{e.class.name}: #{e.message}"
          Rails.logger.error e.backtrace.join("\n") if Rails.env.development?
          redirect_to auth_login_path, alert: "Token exchange failed: #{e.message}"
          return
        end
      end

      # Try to get user info from ID token first, fallback to userinfo endpoint
      user_info = nil

      # First try to extract from ID token (JWT) - more efficient
      begin
        id_token = token_data["id_token"]
        if id_token.present?
          # Decode JWT without signature verification for now (OIDC provider should be trusted)
          # In production, you should verify the signature using the provider's JWKS
          jwt_payload = JWT.decode(id_token, nil, false).first
          user_info = jwt_payload
          Rails.logger.debug "User info extracted from ID token: #{user_info.except("exp", "iat", "auth_time")}"
        end
      rescue JWT::DecodeError => e
        Rails.logger.warn "Failed to decode ID token, will try userinfo endpoint: #{e.message}"
      rescue => e
        Rails.logger.warn "Failed to extract user info from ID token, will try userinfo endpoint: #{e.class.name}: #{e.message}"
      end

      # Fallback to userinfo endpoint if ID token didn't work
      if user_info.blank?
        begin
          uri = URI.parse(oidc_client.userinfo_endpoint)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = 10
          http.read_timeout = 10

          request = Net::HTTP::Get.new(uri.request_uri)
          request["Authorization"] = "Bearer #{tokens.access_token}"
          request["Accept"] = "application/json"

          response = http.request(request)

          unless response.is_a?(Net::HTTPSuccess)
            Rails.logger.error "Userinfo request failed: #{response.code} #{response.message} - #{response.body}"
            redirect_to auth_login_path, alert: "Failed to retrieve user information"
            return
          end

          user_info = JSON.parse(response.body)
          Rails.logger.debug "Userinfo retrieved successfully via manual request"
        rescue => e
          Rails.logger.error "Failed to get userinfo: #{e.class.name}: #{e.message}"
          Rails.logger.error e.backtrace.join("\n") if Rails.env.development?
          redirect_to auth_login_path, alert: "Failed to retrieve user information"
          return
        end
      end

      # Ensure we have user info at this point
      if user_info.blank?
        Rails.logger.error "Unable to get user information from ID token or userinfo endpoint"
        redirect_to auth_login_path, alert: "Failed to retrieve user information"
        return
      end

      # Process authentication
      Rails.logger.info "About to process authentication..."
      handle_authentication(user_info, tokens)
      Rails.logger.info "Authentication processing completed"

    rescue => e
      # Catch any remaining errors
      Rails.logger.error "OIDC callback error: #{e.class.name}: #{e.message}"
      Rails.logger.error e.backtrace.join("\n") if Rails.env.development?
      redirect_to auth_login_path, alert: "Authentication failed: #{e.message}"
    ensure
      # Always clear session flags to prevent double submission
      session.delete(:auth_code_used)
      session.delete(:auth_state)
      session.delete(:auth_code_verifier)
    end
  end

  # GET /auth/failure - Handle authentication failures
  def failure
    error = params[:error] || "Unknown error"
    description = params[:error_description] || "Authentication failed"

    Rails.logger.error "OIDC authentication failure: #{error} - #{description}"

    render plain: "Authentication failed: #{description}", status: :bad_request
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
    Rails.logger.info "Starting handle_authentication..."

    # user_info is now a Hash, not an object with methods
    email = user_info['email']
    name = user_info['name'] || user_info['preferred_username'] || email&.split('@')&.first
    provider = SplatAuthorization.provider_name

    Rails.logger.info "User info extracted: email=#{email}, name=#{name}, provider=#{provider}"

    # Check if user is authorized
    unless SplatAuthorization.authorized?(email)
      Rails.logger.warn "Unauthorized login attempt: #{email} from #{provider}"
      render plain: "Access denied. Your email (#{email}) is not authorized to access this application.", status: :forbidden
      return
    end

    Rails.logger.info "User authorized: #{email}"

    # Create encrypted token from OIDC response
    begin
      encrypted_token = EncryptedToken.from_oidc_response(user_info, tokens, provider)
      Rails.logger.info "Encrypted token created successfully"
    rescue => e
      Rails.logger.error "Failed to create encrypted token: #{e.message}"
      Rails.logger.error e.backtrace.join("\n") if Rails.env.development?
      render plain: "Failed to process authentication: #{e.message}", status: :internal_server_error
      return
    end

    # Store token in encrypted cookie
    if TokenEncryptionService.store_token(cookies, encrypted_token)
      # Log successful authentication
      Rails.logger.info "User authenticated: #{email} via #{provider} (stored in encrypted cookie)"
    else
      Rails.logger.error "Failed to store encrypted token for #{email}"
      redirect_to root_path, alert: "Authentication succeeded but failed to store session. Please try again."
      return
    end

    Rails.logger.info "Redirecting to root path with success message"
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
    Rails.logger.info("Loading OIDC From discovery")
    Rails.cache.fetch("auth:oidc-configuration", expires_in: 5.minutes) do

      base_url = ENV.fetch("OIDC_DISCOVERY_URL")
      # Ensure the discovery URL includes the well-known path (using correct OIDC standard with hyphen)
      discovery_path = "/.well-known/openid-configuration"
      discovery_url = if base_url.include?(discovery_path)
        base_url
      else
        "#{base_url.chomp("/")}/#{discovery_path}"
      end
      Rails.logger.info "Loading OIDC configuration from discovery URL: #{discovery_url}"

      uri = URI.parse(discovery_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 5
      http.read_timeout = 5

      response = http.get(uri.request_uri)

      # Handle HTTP redirects
      if response.is_a?(Net::HTTPRedirection)
        redirect_uri = URI.parse(response["location"])
        Rails.logger.info "Following redirect to: #{redirect_uri}"
        uri = redirect_uri
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
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

      # discovery_data
    end
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
    protocol = Rails.env.development? ? 'http' : ENV.fetch('RAILS_HOST_PROTOCOL', 'https')
    "#{protocol}://#{ENV.fetch('SPLAT_HOST', 'localhost:3030')}/auth/callback"
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
      # Generate a random 43-128 character string using proper base64url encoding
      # This generates 32 bytes = 256 bits, then base64url encode = 43 characters minimum
      SecureRandom.urlsafe_base64(32)
    end

    def code_challenge(verifier)
      # Base64 URL encode the SHA256 hash of the verifier with no padding
      Digest::SHA256.base64digest(verifier).tr("+/", "-_").tr("=", "")
    end
  end
end
