# OpenID Connect Client Configuration
# This replaces OmniAuth with direct OpenID Connect gem usage
require "json"

# OIDC configuration is now handled per-request in AuthController
# This initializer is kept for backward compatibility but the client
# creation has been moved to the controller for better error handling

Rails.application.configure do
  config.after_initialize do
    if OidcConfig.configured?
      Rails.logger.info "OIDC authentication configured for #{ENV['OIDC_PROVIDER_NAME'] || 'OIDC Provider'}"
    else
      Rails.logger.info "OIDC authentication not configured"
    end
  end
end

# Load OIDC configuration from discovery URL or individual endpoints
def load_oidc_configuration
  if ENV['OIDC_DISCOVERY_URL'].present?
    # Use discovery URL (preferred method)
    config_from_discovery
  else
    # Fall back to individual endpoint configuration
    config_from_env_vars
  end
rescue => e
  Rails.logger.error "Failed to load OIDC configuration: #{e.message}"
  raise e
end

def config_from_discovery
  discovery_url = ENV.fetch('OIDC_DISCOVERY_URL')
  Rails.logger.info "Loading OIDC configuration from discovery URL: #{discovery_url}"

  uri = URI.parse(discovery_url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == 'https'
  http.open_timeout = 5
  http.read_timeout = 5

  response = http.get(uri.request_uri)
  response.raise_for_status

  discovery_data = JSON.parse(response.body).with_indifferent_access

  {
    authorization_endpoint: discovery_data[:authorization_endpoint],
    token_endpoint: discovery_data[:token_endpoint],
    userinfo_endpoint: discovery_data[:userinfo_endpoint],
    jwks_uri: discovery_data[:jwks_uri]
  }
rescue JSON::ParserError => e
  Rails.logger.error "Failed to parse OIDC discovery response as JSON: #{e.message}"
  raise "Invalid JSON response from OIDC discovery endpoint: #{e.message}"
rescue Net::TimeoutError => e
  Rails.logger.error "OIDC discovery request timed out: #{e.message}"
  raise "OIDC discovery endpoint timed out: #{e.message}"
rescue Net::HTTPError => e
  Rails.logger.error "OIDC discovery HTTP error: #{e.message}"
  raise "OIDC discovery endpoint returned error: #{e.message}"
end

def config_from_env_vars
  Rails.logger.info "Loading OIDC configuration from environment variables"

  {
    authorization_endpoint: ENV.fetch('OIDC_AUTH_ENDPOINT'),
    token_endpoint: ENV.fetch('OIDC_TOKEN_ENDPOINT'),
    userinfo_endpoint: ENV.fetch('OIDC_USERINFO_ENDPOINT'),
    jwks_uri: ENV.fetch('OIDC_JWKS_ENDPOINT')
  }
end

# Helper methods for OIDC configuration
module OidcConfig
  extend self

  def configured?
    if discovery_url_present?
      discovery_configured?
    else
      manual_configured?
    end
  end

  def provider_name
    ENV.fetch('OIDC_PROVIDER_NAME', 'OpenID Connect')
  end

  def configuration_errors
    if discovery_url_present?
      missing_vars = discovery_required_vars.select { |var| ENV[var].blank? }
      return ["Missing required OIDC environment variables for discovery: #{missing_vars.join(', ')}"] if missing_vars.any?
    else
      missing_vars = manual_required_vars.select { |var| ENV[var].blank? }
      return ["Missing required OIDC environment variables: #{missing_vars.join(', ')}"] if missing_vars.any?
    end

    []
  end

  private

  def discovery_url_present?
    ENV['OIDC_DISCOVERY_URL'].present?
  end

  def discovery_configured?
    discovery_required_vars.all? { |var| ENV[var].present? }
  end

  def manual_configured?
    manual_required_vars.all? { |var| ENV[var].present? }
  end

  def discovery_required_vars
    %w[
      OIDC_CLIENT_ID
      OIDC_CLIENT_SECRET
      OIDC_DISCOVERY_URL
    ]
  end

  def manual_required_vars
    %w[
      OIDC_CLIENT_ID
      OIDC_CLIENT_SECRET
      OIDC_AUTH_ENDPOINT
      OIDC_TOKEN_ENDPOINT
      OIDC_USERINFO_ENDPOINT
      OIDC_JWKS_ENDPOINT
    ]
  end
end

# Alias for easier access
def oidc_configured?
  OidcConfig.configured?
end