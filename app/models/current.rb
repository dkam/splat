# frozen_string_literal: true

class Current < ActiveSupport::CurrentAttributes
  attribute :splat_host
  attribute :splat_internal_host
  attribute :project
  attribute :ip
  attribute :current_user

  def self.splat_host
    @splat_host || ENV.fetch("SPLAT_HOST", "localhost:3000")
  end

  def self.splat_internal_host
    @splat_internal_host || ENV.fetch("SPLAT_INTERNAL_HOST", nil)
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
