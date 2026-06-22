# Sentry Error Tracking
# Only initialize in production environment and only if DSN is configured
Rails.application.configure do
  if Rails.env.production? && ENV["SENTRY_DSN"].present?
    Sentry.init do |config|
      config.breadcrumbs_logger = [:active_support_logger, :http_logger]
      config.dsn = ENV["SENTRY_DSN"]

      # Set the environment tag
      config.environment = Rails.env

      # Release version - use Splat::VERSION
      config.release = Splat::VERSION

      # Sample rate for error events (100% for errors)
      config.sample_rate = 1.0

      # Performance monitoring. Sample Splat's own web traffic (controllers /
      # API) heavily so we get good visibility into the UI in splat-splat, but
      # sample the high-volume ingest/processing pipeline lightly to keep the
      # transaction count manageable.
      #   SENTRY_TRACES_SAMPLE_RATE_WEB  — inbound web requests   (default 1.0)
      #   SENTRY_TRACES_SAMPLE_RATE      — everything else / jobs (default 0.1)
      web_traces_rate = ENV.fetch("SENTRY_TRACES_SAMPLE_RATE_WEB", 1.0).to_f
      pipeline_traces_rate = ENV.fetch("SENTRY_TRACES_SAMPLE_RATE", 0.1).to_f

      config.traces_sampler = lambda do |sampling_context|
        op = sampling_context.dig(:transaction_context, :op).to_s
        name = sampling_context.dig(:transaction_context, :name).to_s
        parent_sampled = sampling_context[:parent_sampled]

        # The envelope-ingest API is Splat's highest-volume endpoint, so treat it
        # as part of the processing pipeline (low rate) rather than the web UI —
        # otherwise the busiest path would dominate splat-splat. Same for the MCP
        # API and health-check polling. Anything not http.server is a job.
        ingest_or_job = !op.start_with?("http.server") ||
          name.start_with?("/api", "Api::", "/mcp", "Mcp::", "/_health", "/up")

        if !parent_sampled.nil?
          # Honour an upstream distributed-trace decision when present.
          parent_sampled ? 1.0 : 0.0
        elsif ingest_or_job
          pipeline_traces_rate
        else
          # Splat's own web UI (dashboards, issues, transactions, settings).
          web_traces_rate
        end
      end

      # Structured logs → splat-splat, so Splat dogfoods its own logs feature as
      # a low-traffic source. enable_logs also makes sentry-rails attach its log
      # subscribers; keep only action_controller (one log per request) and drop
      # the default active_record subscriber, whose per-SQL-query logs would
      # firehose splat-splat given Splat's own ingest write volume.
      config.enable_logs = true
      config.rails.structured_logging.subscribers = {
        action_controller: Sentry::Rails::LogSubscribers::ActionControllerSubscriber
      }

      # Keep splat-splat low-traffic: drop request logs from Splat's high-volume
      # server paths (envelope ingest, MCP, health/up) — the same paths the
      # traces sampler treats as pipeline — leaving just the admin web UI.
      config.before_send_log = lambda do |log|
        path = log.attributes[:path].to_s
        controller = log.attributes[:controller].to_s
        high_volume = path.start_with?("/api", "/mcp", "/_health", "/up") ||
          controller.start_with?("Api::", "Mcp::")
        high_volume ? nil : log
      end

      # Filter out sensitive data
      config.send_default_pii = false

      # Filter out certain exceptions
      config.excluded_exceptions += [
        "ActionController::RoutingError",
        "ActionController::InvalidAuthenticityToken",
        "CGI::Session::CookieStore::TamperedWithCookie",
        "ActionController::UnknownAction",
        "ActionController::UnknownFormat",
        "Mongoid::Errors::DocumentNotFound",
        "AbstractController::ActionNotFound"
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
