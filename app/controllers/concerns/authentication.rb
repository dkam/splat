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
    return if authenticated?

    session[:return_to] = request.fullpath if request.get? && !request.xhr?
    redirect_to login_path
  end

  def start_new_session_for(user_info)
    session[:user_email] = user_info[:email]
    session[:user_name] = user_info[:name]
    session[:provider] = user_info[:provider]
    session[:authenticated_at] = Time.current
  end

  def terminate_session
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
end