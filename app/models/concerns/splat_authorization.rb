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
    # Try OIDC session first
    return session[:user_email] if session[:user_email].present?
    # Fall back to ForwardAuth (set by ForwardAuthController)
    @current_forward_auth_user[:email] if @current_forward_auth_user
  end

  def current_user_name
    # Try OIDC session first
    return session[:user_name] if session[:user_name].present?
    # Fall back to ForwardAuth
    return @current_forward_auth_user[:name] if @current_forward_auth_user
    # Fall back to email
    current_user_email&.split('@')&.first
  end

  def current_user_provider
    # Try OIDC session first
    return session[:provider] if session[:provider].present?
    # Fall back to ForwardAuth
    return @current_forward_auth_user[:provider] if @current_forward_auth_user
  end

  def current_user_authenticated_at
    # Try OIDC session first
    return session[:authenticated_at] if session[:authenticated_at].present?
    # Fall back to ForwardAuth
    return @current_forward_auth_user[:authenticated_at] if @current_forward_auth_user
  end

  def authenticated?
    # Check OIDC session first
    return true if session[:user_email].present? && session[:provider].present?
    # Fall back to ForwardAuth
    return true if @current_forward_auth_user.present?
    false
  end

  def authorized_user?
    authenticated? && SplatAuthorization.authorized?(current_user_email)
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
    return true unless session[:expires_at] # Some providers don't send expiry

    Time.current < Time.at(session[:expires_at])
  end

  # Refresh access token if needed (OIDC only)
  def refresh_access_token_if_needed
    return if forward_auth_request? # ForwardAuth doesn't use tokens
    return unless authenticated?
    return unless session[:expires_at]
    return unless session[:refresh_token]
    return if Time.current < Time.at(session[:expires_at] - 300) # Refresh 5 minutes before expiry

    begin
      # This would require implementing token refresh logic
      # For now, we'll just let the session expire naturally
      Rails.logger.info "Token refresh needed but not implemented"
    rescue => e
      Rails.logger.error "Failed to refresh access token: #{e.message}"
      reset_session
    end
  end

  # Check if we're using ForwardAuth for this request
  def forward_auth_request?
    @current_forward_auth_user.present?
  end

  end