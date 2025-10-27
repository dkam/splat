# OpenID Connect Client Configuration
# This replaces OmniAuth with direct OpenID Connect gem usage

Rails.application.configure do
  config.after_initialize do
    # Only configure if OIDC is properly set up
    next unless oidc_configured?

    # Configure OpenID Connect client
    Rails.application.config.oidc_client = OpenIDConnect::Client.new({
      identifier: ENV.fetch('OIDC_CLIENT_ID'),
      secret: ENV.fetch('OIDC_CLIENT_SECRET'),
      authorization_endpoint: ENV.fetch('OIDC_AUTH_ENDPOINT'),
      token_endpoint: ENV.fetch('OIDC_TOKEN_ENDPOINT'),
      userinfo_endpoint: ENV.fetch('OIDC_USERINFO_ENDPOINT'),
      jwks_uri: ENV.fetch('OIDC_JWKS_ENDPOINT'),
      redirect_uri: "#{ENV.fetch('RAILS_HOST_PROTOCOL', 'http')}://#{ENV.fetch('RAILS_HOST', 'localhost:3000')}/auth/callback"
    })

    Rails.logger.info "OpenID Connect client configured for #{ENV['OIDC_PROVIDER_NAME'] || 'OIDC Provider'}"
  end
end

# Helper methods for OIDC configuration
module OidcConfig
  extend self

  def configured?
    required_env_vars.all? { |var| ENV[var].present? }
  end

  def provider_name
    ENV.fetch('OIDC_PROVIDER_NAME', 'OpenID Connect')
  end

  def configuration_errors
    missing_vars = required_env_vars.select { |var| ENV[var].blank? }
    return [] if missing_vars.empty?

    ["Missing required OIDC environment variables: #{missing_vars.join(', ')}"]
  end

  private

  def required_env_vars
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