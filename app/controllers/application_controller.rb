class ApplicationController < ActionController::Base
  include SplatAuthorization

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :set_current_attributes
  before_action :require_authentication
  before_action :refresh_access_token_if_needed

  helper_method :queue_depth, :current_user_email, :current_user_name, :current_user_provider,
                :current_user_authenticated_at, :authenticated?, :authorized_user?,
                :oidc_configured?, :session_valid?

  private

  def set_current_attributes
    Current.splat_host = ENV.fetch("SPLAT_HOST", "localhost:3030")
    Current.splat_internal_host = ENV.fetch("SPLAT_INTERNAL_HOST", nil)
  end

  def queue_depth
    @queue_depth ||= SolidQueue::ReadyExecution.count
  end

  def require_authentication
    # No authentication required
    return if auth_mode_none?

    # Already authenticated (OIDC or ForwardAuth)
    return if authorized_user?

    # Handle different authentication modes
    case SplatAuthorization.auth_mode
    when 'forward_auth'
      # ForwardAuth mode - require headers from allowed proxy IPs
      unless request_from_allowed_proxy?
        Rails.logger.warn "ForwardAuth: Access denied from IP #{request.remote_ip} (not in allowed list)"
        render json: { error: 'Access denied' }, status: :forbidden
        return
      end

      # No ForwardAuth headers present
      Rails.logger.warn "ForwardAuth: No authentication headers from allowed proxy IP #{request.remote_ip}"
      render json: { error: 'Authentication required' }, status: :unauthorized

    when 'oidc'
      # OIDC mode - redirect to login
      session[:return_to] = request.fullpath if request.get? && !request.xhr?

      unless oidc_configured?
        if SplatAuthorization.configuration_errors.any?
          render plain: "OIDC authentication is not properly configured. #{SplatAuthorization.configuration_errors.join(' ')}", status: :service_unavailable
        else
          render plain: "Authentication is not configured. Please contact an administrator.", status: :service_unavailable
        end
        return
      end

      redirect_to auth_login_path

    else
      # Unknown authentication mode
      Rails.logger.error "Unknown authentication mode: #{SplatAuthorization.auth_mode}"
      render json: { error: 'Authentication configuration error' }, status: :internal_server_error
    end
  end
end