require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Splat doesn't process image variants (no user uploads of images that need
  # resizing). Disabling silences the ActiveStorage "image_processing gem
  # required" warning that fires on every Rails boot otherwise.
  config.active_storage.variant_processor = :disabled

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache digest stamped assets for far-future expiry.
  # Short cache for others: robots.txt, sitemap.xml, 404.html, etc.
  config.public_file_server.headers = {
    "cache-control" => lambda do |path, _|
      if path.start_with?("/assets/")
        # Files in /assets/ are expected to be fully immutable.
        # If the content change the URL too.
        "public, immutable, max-age=#{1.year.to_i}"
      else
        # For anything else we cache for 1 minute.
        "public, max-age=#{1.minute.to_i}, stale-while-revalidate=#{5.minutes.to_i}"
      end
    end
  }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Assume all access is through a TLS-terminating reverse proxy (the default —
  # how splat.booko.info runs behind Caddy). A bare-HTTP deployment reached
  # directly on :3030 with no proxy must set both to false: otherwise Rails
  # builds https:// base URLs while the browser sends an http:// Origin, and
  # the CSRF origin check 422s every form POST.
  config.assume_ssl = ENV.fetch("SPLAT_ASSUME_SSL", "true") != "false"

  # Force all access over SSL, use Strict-Transport-Security and secure cookies.
  config.force_ssl = ENV.fetch("SPLAT_FORCE_SSL", "true") != "false"

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  # Prefix every line with an ISO8601 millisecond timestamp so docker log
  # output is timestamped even without `docker logs --timestamps`. Built on
  # SimpleFormatter so TaggedLogging.new can extend it with its tagging module.
  config.log_tags = [:request_id]
  timestamped_formatter = Class.new(ActiveSupport::Logger::SimpleFormatter) do
    def call(severity, time, _progname, msg)
      "[#{time.utc.iso8601(3)}] #{severity.ljust(5)} #{msg}\n"
    end
  end
  base_logger = Logger.new($stdout)
  base_logger.formatter = timestamped_formatter.new
  config.logger = ActiveSupport::TaggedLogging.new(base_logger)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  config.active_job.queue_adapter = :tuber

  # Email (issue + burst alerts). Driven entirely by ENV so no credentials live
  # in the repo. Email stays inert until SMTP_ADDRESS is set; ntfy is independent.
  # raise_delivery_errors=false keeps a missing/misconfigured relay from failing
  # alert delivery (errors are logged, not raised).
  config.action_mailer.default_url_options = {host: ENV.fetch("SPLAT_HOST", "localhost:3000")}
  config.action_mailer.perform_deliveries = ENV["SMTP_ADDRESS"].present?
  config.action_mailer.raise_delivery_errors = false
  config.action_mailer.delivery_method = :smtp
  config.action_mailer.smtp_settings = {
    address: ENV.fetch("SMTP_ADDRESS", "localhost"),
    port: ENV.fetch("SMTP_PORT", 587).to_i,
    domain: ENV["SMTP_DOMAIN"],
    user_name: ENV["SMTP_USER_NAME"],
    password: ENV["SMTP_PASSWORD"],
    authentication: ENV.fetch("SMTP_AUTHENTICATION", "plain").to_sym,
    enable_starttls_auto: ENV.fetch("SMTP_ENABLE_STARTTLS_AUTO", "true") == "true"
  }.compact

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [:id]

  # Enable DNS rebinding protection and other `Host` header attacks.
  # config.hosts = [
  #   "example.com",     # Allow requests from example.com
  #   /.*\.example\.com/ # Allow requests from subdomains like `www.example.com`
  # ]
  #
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
