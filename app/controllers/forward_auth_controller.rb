class ForwardAuthController < ApplicationController
  skip_before_action :require_authentication, only: [:authenticate]

  # GET /forward_auth/authenticate - Header-based ForwardAuth endpoint
  def authenticate
    # Only allow ForwardAuth endpoint in ForwardAuth mode
    unless SplatAuthorization.auth_mode_forward_auth?
      Rails.logger.warn "ForwardAuth endpoint accessed but auth mode is: #{SplatAuthorization.auth_mode}"
      head 403
      return
    end

    # Check if request is from allowed proxy IP (if configured)
    unless request_from_allowed_proxy?
      Rails.logger.warn "ForwardAuth: Access denied from IP #{request.remote_ip} (not in allowed proxy IPs)"
      head 403
      return
    end

    # Header-based ForwardAuth - trust external auth provider headers
    # Headers ARE the authentication source, not just informational

    user_email = extract_user_email
    user_name = extract_user_name
    user_groups = extract_user_groups

    # Debug logging for development
    Rails.logger.debug "ForwardAuth request - Email: #{user_email}, Name: #{user_name}, Groups: #{user_groups}"
    Rails.logger.debug "All auth headers: #{auth_headers.inspect}" if Rails.env.development?

    # Check if we have required authentication headers
    if user_email.blank?
      Rails.logger.warn "ForwardAuth: No user email found in headers"
      head 401
      return
    end

    # Check if user is authorized to access this application
    unless SplatAuthorization.authorized?(user_email)
      Rails.logger.warn "ForwardAuth: Unauthorized user #{user_email} attempted access"
      head 403
      return
    end

    # User is authenticated and authorized
    # Store user info in session for this request only (no persistent session)
    @current_forward_auth_user = {
      email: user_email,
      name: user_name || user_email.split('@').first,
      groups: user_groups,
      authenticated_at: Time.current,
      provider: 'ForwardAuth'
    }

    Rails.logger.info "ForwardAuth: User #{user_email} authenticated successfully"

    # Return success with user info in headers for Caddy's use
    response.headers['X-ForwardAuth-User'] = @current_forward_auth_user[:email]
    response.headers['X-ForwardAuth-Name'] = @current_forward_auth_user[:name]
    response.headers['X-ForwardAuth-Groups'] = @current_forward_auth_user[:groups].join(',') if @current_forward_auth_user[:groups].any?
    response.headers['X-ForwardAuth-Authenticated-At'] = @current_forward_auth_user[:authenticated_at].iso8601

    head 200
  end

  private

  def extract_user_email
    # Try different header names for email
    auth_headers['X-Forwarded-Email'] ||
      auth_headers['X-Forwarded-User'] ||
      auth_headers['X-Auth-Email'] ||
      auth_headers['X-Auth-User'] ||
      auth_headers['X-Webauth-User'] ||
      auth_headers['Remote-User'] ||
      auth_headers['Remote-Email']
  end

  def extract_user_name
    # Try different header names for name
    auth_headers['X-Forwarded-Name'] ||
      auth_headers['X-Forwarded-Display-Name'] ||
      auth_headers['X-Auth-Name'] ||
      auth_headers['X-Auth-Display-Name'] ||
      auth_headers['X-Webauth-Name'] ||
      auth_headers['Remote-Name']
  end

  def extract_user_groups
    # Groups can be comma-separated or single value
    groups_header = auth_headers['X-Forwarded-Group'] ||
                   auth_headers['X-Forwarded-Groups'] ||
                   auth_headers['X-Auth-Group'] ||
                   auth_headers['X-Auth-Groups'] ||
                   auth_headers['X-Webauth-Groups']

    return [] if groups_header.blank?

    # Split comma-separated groups and clean them up
    groups = groups_header.to_s.split(',').map(&:strip).reject(&:blank?)
    groups.map { |group| group.gsub(/^["']|["']$/, '') } # Remove quotes
  end

  def auth_headers
    @auth_headers ||= request.headers.select { |key, value|
      key.to_s.match?(/^(X-Forwarded|X-Auth|X-Webauth|Remote)-/i)
    }
  end

  # Override current_user methods for ForwardAuth requests
  def current_user_email
    @current_forward_auth_user[:email] if @current_forward_auth_user
  end

  def current_user_name
    @current_forward_auth_user[:name] if @current_forward_auth_user
  end

  def current_user_provider
    @current_forward_auth_user[:provider] if @current_forward_auth_user
  end

  def authenticated_user?
    @current_forward_auth_user.present?
  end

  # For ForwardAuth, authentication is per-request, not session-based
  def authorized_user?
    authenticated_user? && SplatAuthorization.authorized?(current_user_email)
  end
end