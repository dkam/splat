require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Splat
  class Application < Rails::Application
    config.secret_key_base = ENV.fetch('SECRET_KEY_BASE') do
      raise "SECRET_KEY_BASE environment variable is required but not set. Please 
  set it in your .env file or environment."
    end
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Email configuration using environment variables
    config.action_mailer.default_url_options = {
      host: ENV.fetch('SPLAT_HOST', 'localhost'),
      port: ENV.fetch('SPLAT_PORT', 3000)
    }

    # Configure SMTP settings using environment variables
    config.action_mailer.delivery_method = :smtp
    config.action_mailer.smtp_settings = {
      address: ENV.fetch('SMTP_ADDRESS', 'localhost'),
      port: ENV.fetch('SMTP_PORT', 587),
      domain: ENV.fetch('SMTP_DOMAIN', 'localhost'),
      user_name: ENV.fetch('SMTP_USER_NAME', nil),
      password: ENV.fetch('SMTP_PASSWORD', nil),
      authentication: ENV.fetch('SMTP_AUTHENTICATION', 'plain').to_sym,
      enable_starttls_auto: ENV.fetch('SMTP_STARTTLS_AUTO', 'true') == 'true',
      openssl_verify_mode: OpenSSL::SSL::VERIFY_PEER
    }

    if ENV['MISSION_CONTROL_USERNAME'].present? && ENV['MISSION_CONTROL_PASSWORD'].present?
      MissionControl::Jobs.http_basic_auth_user = ENV['MISSION_CONTROL_USERNAME']
      MissionControl::Jobs.http_basic_auth_password = ENV['MISSION_CONTROL_PASSWORD']
    end
  end
end