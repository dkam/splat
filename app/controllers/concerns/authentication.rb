module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :authenticated?, :current_user_email, :current_user_name, :current_user_provider, :current_user_authenticated_at
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private

  def authenticated?
    session[:user_email].present?
  end

  def require_authentication
    return if !SplatAuthorization.oidc_configured?  # Allow access if OIDC not configured
    return if authenticated? && oidc_session_valid?

    session[:return_to] = request.fullpath if request.get? && !request.xhr?
    redirect_to login_path
  end

  def start_new_session_for(user_info, sid: nil)
    session[:user_email] = user_info[:email]
    session[:user_name] = user_info[:name]
    session[:provider] = user_info[:provider]
    session[:authenticated_at] = Time.current
    session[:oidc_sid] = sid if sid.present?

    # Create OIDC session mapping for backchannel logout if we have a sid
    if sid.present?
      begin
        OidcSession.create_for_user(
          oidc_sid: sid,
          session_id: session.id&.to_s || request.session_options[:id],
          user_email: user_info[:email]
        )
        Rails.logger.info "Created OIDC session mapping: sid=#{sid}, email=#{user_info[:email]}"
      rescue => e
        Rails.logger.error "Failed to create OIDC session mapping: #{e.message}"
        # Don't fail authentication if we can't track the session
      end
    end
  end

  def terminate_session
    # Clean up OIDC session mapping if present
    if session[:oidc_sid].present?
      begin
        oidc_session = OidcSession.find_by_oidc_sid(session[:oidc_sid])
        oidc_session&.destroy
        Rails.logger.info "Removed OIDC session mapping: sid=#{session[:oidc_sid]}"
      rescue => e
        Rails.logger.error "Failed to remove OIDC session mapping: #{e.message}"
      end
    end

    reset_session
  end

  def current_user_email
    session[:user_email]
  end

  def current_user_name
    session[:user_name]
  end

  def current_user_provider
    session[:provider]
  end

  def current_user_authenticated_at
    session[:authenticated_at]
  end

  def oidc_session_valid?
    # If we don't have an OIDC session ID, assume it's valid (fallback behavior)
    return true unless session[:oidc_sid].present?

    begin
      # Check if the OIDC session still exists and is not expired
      oidc_session = OidcSession.find_by_oidc_sid(session[:oidc_sid])

      if oidc_session.nil?
        # Session was invalidated via backchannel logout, clear the user's session
        Rails.logger.info "OIDC session invalidated, forcing logout: sid=#{session[:oidc_sid]}"
        force_logout_due_to_invalid_session
        return false
      end

      true
    rescue => e
      Rails.logger.error "Error checking OIDC session validity: #{e.message}"
      # If we can't check validity, assume it's valid to avoid breaking access
      true
    end
  end

  def force_logout_due_to_invalid_session
    # Store a message for the user to understand why they were logged out
    flash[:alert] = "Your session was terminated from another device. Please log in again."

    # Clear the session
    reset_session
  end
end
