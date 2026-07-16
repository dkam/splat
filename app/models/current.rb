# frozen_string_literal: true

class Current < ActiveSupport::CurrentAttributes
  attribute :splat_host
  attribute :splat_internal_host
  attribute :project
  attribute :ip
  attribute :current_user

  # Instance readers, so `super` reaches the attribute CurrentAttributes wrote.
  # These used to be `def self.splat_host` reading an `@splat_host` class ivar,
  # which nothing ever assigned — `Current.splat_host = ...` stores into the
  # attributes hash — so the reader silently ignored whatever the request set
  # and always answered from ENV. The ENV fallback still covers jobs, mailers
  # and anything else running outside a request.
  def splat_host
    super.presence || ENV.fetch("SPLAT_HOST", "localhost:3000")
  end

  def splat_internal_host
    super.presence || ENV.fetch("SPLAT_INTERNAL_HOST", nil)
  end

  # Scheme + authority for URLs we hand to clients (project DSNs, the MCP
  # endpoint). Local hosts are assumed plaintext; anything else is assumed to
  # be fronted by TLS, which is true of every real deployment.
  def self.external_base_url
    host = splat_host
    scheme = host.include?("localhost") ? "http" : "https"
    "#{scheme}://#{host}"
  end

  # Get current user information from encrypted cookies or fallback mechanisms
  def self.current_user_info(controller_context = nil)
    return @current_user_info if @current_user_info.present?

    # Try to get user info from controller context if available
    if controller_context
      user_info = TokenEncryptionService.current_user_info(controller_context.cookies)
      return nil unless user_info

      @current_user_info = {
        email: user_info[:email],
        name: user_info[:name],
        provider: user_info[:provider],
        authenticated_at: user_info[:authenticated_at],
        expires_at: user_info[:expires_at]
      }
    end

    @current_user_info
  end

  # Reset current user info (useful for testing or forced refresh)
  def self.reset_current_user!
    @current_user_info = nil
  end

  # Check if user is authenticated via encrypted tokens
  def self.authenticated?(controller_context = nil)
    return true if current_user.present?
    return false unless controller_context

    TokenEncryptionService.authenticated?(controller_context.cookies)
  end

  # Get current user email
  def self.current_user_email(controller_context = nil)
    current_user_info(controller_context)&.dig(:email)
  end

  # Get current user name
  def self.current_user_name(controller_context = nil)
    current_user_info(controller_context)&.dig(:name)
  end

  # Get current user provider
  def self.current_user_provider(controller_context = nil)
    current_user_info(controller_context)&.dig(:provider)
  end

  # Get current user authentication time
  def self.current_user_authenticated_at(controller_context = nil)
    current_user_info(controller_context)&.dig(:authenticated_at)
  end
end
