# Sentry Error Tracking
# Only initialize in production environment and only if DSN is configured
Rails.application.configure do
  if Rails.env.production? && ENV['SENTRY_DSN'].present?
    Sentry.init do |config|
      config.breadcrumbs_logger = [:active_support_logger, :http_logger]
      config.dsn = ENV['SENTRY_DSN']
      
      # Set the environment tag
      config.environment = Rails.env

      # Release version - timestamp with git hash
      config.release = "#{DateTime.current.beginning_of_hour.iso8601}-#{`git rev-parse --short HEAD`.strip}"

      # Sample rate for error events (100% for errors)
      config.sample_rate = 1.0

      # Performance monitoring - enable with low sample rate
      config.traces_sample_rate = ENV.fetch('SENTRY_TRACES_SAMPLE_RATE', 0.1).to_f

      # Filter out sensitive data
      config.send_default_pii = false

      # Filter out certain exceptions
      config.excluded_exceptions += [
        'ActionController::RoutingError',
        'ActionController::InvalidAuthenticityToken',
        'CGI::Session::CookieStore::TamperedWithCookie',
        'ActionController::UnknownAction',
        'ActionController::UnknownFormat',
        'Mongoid::Errors::DocumentNotFound',
        'AbstractController::ActionNotFound'
      ]

      # Before send callback for additional filtering
      config.before_send = lambda do |event, hint|
        # Filter out events from certain IPs if needed
        # event.tags[:filtered] = 'true' if some_condition

        # Don't send events in certain cases
        # return nil if should_filter_event?(event)

        event
      end
    end

    # Rails.logger.info "Sentry initialized in production environment with DSN: #{ENV['SENTRY_DSN']&.split('@')&.last}"
  end
end