module SplatAuthorization
  extend ActiveSupport::Concern

  class << self
    # Check if an email is authorized to access the application
    def authorized?(email)
      return false if email.blank?

      # Normalize email (lowercase and strip)
      email = email.downcase.strip

      # Check exact email matches first (specific users)
      return true if allowed_emails.include?(email)

      # Check domain matches (including subdomains)
      domain = email.split('@').last
      allowed_domains.any? { |allowed| domain_matches?(domain, allowed) }
    end

    # Check if OIDC is configured and ready
    def oidc_configured?
      OidcConfig.configured?
    end

    # Get provider display name
    def provider_name
      OidcConfig.provider_name
    end

    # Get configuration errors for display
    def configuration_errors
      OidcConfig.configuration_errors
    end

    # Get current authentication mode
    def auth_mode
      @auth_mode ||= ENV.fetch('SPLAT_AUTH_MODE', 'none').downcase
    end

    # Check if no authentication required
    def auth_mode_none?
      auth_mode == 'none'
    end

    # Check if OIDC mode is enabled
    def auth_mode_oidc?
      auth_mode == 'oidc'
    end

    # Check if ForwardAuth mode is enabled
    def auth_mode_forward_auth?
      auth_mode == 'forward_auth'
    end

    # Get allowed ForwardAuth proxy IPs
    def forward_auth_proxy_ips
      @forward_auth_proxy_ips ||= ENV.fetch('FORWARD_AUTH_PROXY_IPS', '').split(',').map(&:strip).reject(&:blank!)
    end

    # Check if request is from allowed ForwardAuth proxy IP
    def request_from_allowed_proxy?(request)
      return true if forward_auth_proxy_ips.empty?  # No IP restrictions

      client_ip = request.remote_ip
      forward_auth_proxy_ips.include?(client_ip)
    end

    # Check if authentication is configured for current mode
    def auth_configured?
      case auth_mode
      when 'none'
        true  # No auth needed
      when 'forward_auth'
        true  # ForwardAuth doesn't need Rails config
      when 'oidc'
        oidc_configured?
      else
        false
      end
    end

    private

    def allowed_emails
      @allowed_emails ||= ENV.fetch('SPLAT_ALLOWED_USERS', '').split(',').map(&:strip).reject(&:blank?).map(&:downcase)
    end

    def allowed_domains
      @allowed_domains ||= ENV.fetch('SPLAT_ALLOWED_DOMAINS', '').split(',').map(&:strip).reject(&:blank?).map(&:downcase)
    end

    # Check if domain matches allowed domain (including subdomains)
    def domain_matches?(domain, allowed)
      return false if domain.blank? || allowed.blank?

      # Exact match
      return true if domain == allowed

      # Subdomain match (e.g., app.booko.au matches booko.au)
      return true if domain.end_with?(".#{allowed}")

      # Wildcard handling (e.g., *.booko.au should match app.booko.au)
      if allowed.start_with?('*.')
        base_domain = allowed[2..-1]  # Remove '*.'
        return domain_matches?(domain, base_domain)
      end

      false
    end
  end

  # Instance methods for inclusion in controllers
  def current_user_email
    current_user_info_from_token[:email]
  end

  def current_user_name
    current_user_info_from_token[:name] || current_user_email&.split('@')&.first
  end

  def current_user_provider
    current_user_info_from_token[:provider]
  end

  def current_user_authenticated_at
    current_user_info_from_token[:authenticated_at]
  end

  def authenticated?
    current_user_info_from_token[:email].present?
  end

  def authorized_user?
    authenticated? && SplatAuthorization.authorized?(current_user_email)
  end

  private

  # Cache decrypted token per request for performance
  def current_user_info_from_token
    @current_user_info ||= begin
      # Try encrypted token first
      user_info = TokenEncryptionService.current_user_info(cookies)
      return user_info if user_info.present?

      # Fall back to session for backward compatibility
      if session[:user_email].present?
        return {
          email: session[:user_email],
          name: session[:user_name],
          provider: session[:provider],
          authenticated_at: session[:authenticated_at]
        }
      end

      # Fall back to ForwardAuth
      if @current_forward_auth_user.present?
        return @current_forward_auth_user
      end

      {}
    end
  end

  def oidc_configured?
    SplatAuthorization.oidc_configured?
  end

  # Check if current request should use ForwardAuth
  def forward_auth_request?
    SplatAuthorization.auth_mode_forward_auth? && @current_forward_auth_user.present?
  end

  # Check if no authentication is required
  def auth_mode_none?
    SplatAuthorization.auth_mode_none?
  end

  # Check if OIDC mode is active
  def auth_mode_oidc?
    SplatAuthorization.auth_mode_oidc?
  end

  # Check if ForwardAuth mode is active
  def auth_mode_forward_auth?
    SplatAuthorization.auth_mode_forward_auth?
  end

  # Check if request is from allowed proxy IP (ForwardAuth mode)
  def request_from_allowed_proxy?
    SplatAuthorization.request_from_allowed_proxy?(request)
  end

  # Check if session is still valid (not expired)
  def session_valid?
    return true if forward_auth_request? # ForwardAuth is per-request
    return false unless authenticated?

    # Check encrypted token validity first
    user_info = TokenEncryptionService.current_user_info(cookies)
    if user_info.present?
      return true if user_info[:expires_at].blank? # Some providers don't send expiry
      return Time.current < user_info[:expires_at]
    end

    # Fall back to session for backward compatibility
    return true unless session[:expires_at]
    Time.current < Time.at(session[:expires_at])
  end

  # Refresh access token if needed (OIDC only)
  def refresh_access_token_if_needed
    return if forward_auth_request? # ForwardAuth doesn't use tokens
    return unless authenticated?

    # Try encrypted token refresh first
    if TokenEncryptionService.token_needs_refresh?(cookies)
      begin
        oidc_client = build_oidc_client_for_refresh
        success = TokenEncryptionService.refresh_access_token(cookies, oidc_client)
        Rails.logger.info "Token refresh #{success ? 'succeeded' : 'failed'}"
        return success
      rescue => e
        Rails.logger.error "Failed to refresh encrypted token: #{e.message}"
        return false
      end
    end

    # Fall back to session refresh for backward compatibility
    return unless session[:expires_at]
    return unless session[:refresh_token]
    return if Time.current < Time.at(session[:expires_at] - 300) # Refresh 5 minutes before expiry

    begin
      # Legacy session-based refresh
      Rails.logger.info "Legacy session token refresh needed but not implemented"
    rescue => e
      Rails.logger.error "Failed to refresh access token: #{e.message}"
      reset_session
    end
  end

  # Check if we're using ForwardAuth for this request
  def forward_auth_request?
    @current_forward_auth_user.present?
  end

  # Clear all authentication data (both encrypted cookies and sessions)
  def clear_authentication!
    # Clear encrypted token cookie
    TokenEncryptionService.clear_token(cookies)

    # Clear any remaining session data
    session_keys = [:user_email, :user_name, :provider, :access_token, :refresh_token, :expires_at, :authenticated_at, :auth_state, :auth_code_verifier]
    session_keys.each { |key| session.delete(key) }

    Rails.logger.info "Cleared all authentication data"
  end

  private

  # Build OIDC client for token refresh (reuses logic from AuthController)
  def build_oidc_client_for_refresh
    # Get OIDC configuration from discovery URL or individual endpoints
    oidc_config = load_oidc_configuration_for_refresh

    # Create client dynamically per request
    client = OpenIDConnect::Client.new({
      identifier: ENV.fetch('OIDC_CLIENT_ID'),
      secret: ENV.fetch('OIDC_CLIENT_SECRET'),
      authorization_endpoint: oidc_config[:authorization_endpoint],
      token_endpoint: oidc_config[:token_endpoint],
      userinfo_endpoint: oidc_config[:userinfo_endpoint],
      jwks_uri: oidc_config[:jwks_uri],
      redirect_uri: oidc_redirect_uri_for_refresh
    })

    Rails.logger.debug "Created OIDC client for token refresh"
    client
  rescue => e
    Rails.logger.error "Failed to create OIDC client for refresh: #{e.message}"
    raise "OIDC configuration error: #{e.message}"
  end

  def load_oidc_configuration_for_refresh
    if ENV['OIDC_DISCOVERY_URL'].present?
      # Use discovery URL (preferred method)
      config_from_discovery_for_refresh
    else
      # Fall back to individual endpoint configuration
      config_from_env_vars_for_refresh
    end
  rescue => e
    Rails.logger.error "Failed to load OIDC configuration for refresh: #{e.message}"
    raise e
  end

  def config_from_discovery_for_refresh
    discovery_url = ENV.fetch('OIDC_DISCOVERY_URL')
    Rails.logger.debug "Loading OIDC configuration from discovery URL for refresh: #{discovery_url}"

    uri = URI.parse(discovery_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = 5
    http.read_timeout = 5

    response = http.get(uri.request_uri)
    response.raise_for_status

    discovery_data = JSON.parse(response.body).with_indifferent_access

    {
      authorization_endpoint: discovery_data[:authorization_endpoint],
      token_endpoint: discovery_data[:token_endpoint],
      userinfo_endpoint: discovery_data[:userinfo_endpoint],
      jwks_uri: discovery_data[:jwks_uri]
    }
  rescue JSON::ParserError => e
    Rails.logger.error "Failed to parse OIDC discovery response as JSON for refresh: #{e.message}"
    raise "Invalid JSON response from OIDC discovery endpoint: #{e.message}"
  rescue Net::TimeoutError => e
    Rails.logger.error "OIDC discovery request timed out for refresh: #{e.message}"
    raise "OIDC discovery endpoint timed out: #{e.message}"
  rescue Net::HTTPError => e
    Rails.logger.error "OIDC discovery HTTP error for refresh: #{e.message}"
    raise "OIDC discovery endpoint returned error: #{e.message}"
  end

  def config_from_env_vars_for_refresh
    Rails.logger.debug "Loading OIDC configuration from environment variables for refresh"

    {
      authorization_endpoint: ENV.fetch('OIDC_AUTH_ENDPOINT'),
      token_endpoint: ENV.fetch('OIDC_TOKEN_ENDPOINT'),
      userinfo_endpoint: ENV.fetch('OIDC_USERINFO_ENDPOINT'),
      jwks_uri: ENV.fetch('OIDC_JWKS_ENDPOINT')
    }
  end

  def oidc_redirect_uri_for_refresh
    "#{ENV.fetch('RAILS_HOST_PROTOCOL', 'http')}://#{ENV.fetch('RAILS_HOST', 'localhost:3000')}/auth/callback"
  end

  end