# Sentry Error Tracking
# Only initialize in production environment and only if DSN is configured
Rails.application.configure do
  if Rails.env.production? && ENV['SENTRY_DSN'].present?
    Sentry.init do |config|
      config.breadcrumbs_logger = [:active_support_logger, :http_logger]
      config.dsn = ENV['SENTRY_DSN']
      
      # Set the environment tag
      config.environment = Rails.env

      # Release version - use Splat::VERSION
      config.release = Splat::VERSION

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
      # Use Rails request_id as transaction_id for easier log correlation
      
      set_request_id = lambda do |event, hint|
        if event.tags && event.tags[:request_id]
          event.event_id = event.tags[:request_id]
        end
        event
      end

      config.before_send_transaction = set_request_id

      # Before send callback for additional filtering
      config.before_send = lambda do |event, hint|
        # Set request_id as event_id for correlation
        set_request_id.call(event, hint)

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