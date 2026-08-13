# frozen_string_literal: true

# Authorization and user access management for Splat
# Handles email allowlist for user access control
module SplatAuthorization
  extend ActiveSupport::Concern

  # The three variables that together stand up an OIDC provider. All three or
  # none — see .oidc_state.
  OIDC_VARS = %w[OIDC_CLIENT_ID OIDC_CLIENT_SECRET OIDC_DISCOVERY_URL].freeze

  # Allowlist variables. Set without a provider they express an intent to
  # restrict access that nothing is enforcing, so boot warns about them — but
  # they don't flip the instance into :misconfigured on their own, being the
  # variables most likely to sit unused in a compose template shared across a
  # fleet where one instance deliberately runs open.
  ALLOWLIST_VARS = %w[SPLAT_ALLOWED_USERS SPLAT_ALLOWED_DOMAINS].freeze

  # Class methods for authorization checks
  class << self
    # Check if user is authorized to access Splat
    # Supports both specific email allowlist and domain allowlist
    def authorized?(email)
      return false if email.blank?

      # Normalize email (lowercase and strip)
      email = email.downcase.strip

      # Check exact email matches first (specific users)
      return true if allowed_emails.include?(email)

      # Check domain matches (including subdomains)
      domain = email.split("@").last
      allowed_domains.any? { |allowed| domain_matches?(domain, allowed) }
    end

    # Three states, not two:
    #
    #   :open          — no OIDC vars at all. Splat is single-tenant and trusts
    #                    the network by design; serve everything.
    #   :enforcing     — all three present. Require a session.
    #   :misconfigured — some but not all. Somebody meant to turn auth on and a
    #                    variable is missing or misspelled.
    #
    # The third state exists because oidc_configured? is not just the login
    # gate: Mcp::McpController#mcp_auth_outcome consults it to decide whether
    # MCP uses per-user tokens, and ApplicationController#refresh_mcp_authentication
    # to decide whether to renew them. A single typo would otherwise flip three
    # subsystems into a different security model with no signal at all, so the
    # UI refuses to serve instead (Authentication#render_auth_misconfigured).
    def oidc_state
      case OIDC_VARS.count { |var| ENV[var].present? }
      when OIDC_VARS.size then :enforcing
      when 0 then :open
      else :misconfigured
      end
    end

    # Check if OIDC is configured and ready
    def oidc_configured?
      oidc_state == :enforcing
    end

    def oidc_misconfigured?
      oidc_state == :misconfigured
    end

    def missing_oidc_vars
      OIDC_VARS.reject { |var| ENV[var].present? }
    end

    # Allowlist set with no provider to authenticate against — nothing is
    # enforcing it. Warned about at boot, not fatal.
    def allowlist_without_provider?
      oidc_state == :open && ALLOWLIST_VARS.any? { |var| ENV[var].present? }
    end

    # Whether anyone at all can pass authorized?. Both lists empty denies
    # everyone, which is the right default — forgetting one variable shouldn't
    # admit a whole domain — but it is indistinguishable from a provider
    # problem once you're staring at "access denied", so the login page warns
    # before the round trip.
    def allowlist_configured?
      allowed_emails.any? || allowed_domains.any?
    end

    private

    def allowed_emails
      @allowed_emails ||= ENV.fetch("SPLAT_ALLOWED_USERS", "").split(",").map(&:strip).reject(&:blank?).map(&:downcase)
    end

    def allowed_domains
      @allowed_domains ||= ENV.fetch("SPLAT_ALLOWED_DOMAINS", "").split(",").map(&:strip).reject(&:blank?).map(&:downcase)
    end

    # Check if domain matches allowed domain (including subdomains)
    def domain_matches?(domain, allowed)
      return false if domain.blank? || allowed.blank?

      # Exact match
      return true if domain == allowed

      # Subdomain match (e.g., app.booko.au matches booko.au)
      return true if domain.end_with?(".#{allowed}")

      # Wildcard handling (e.g., *.booko.au should match app.booko.au)
      if allowed.start_with?("*.")
        base_domain = allowed[2..]  # Remove "*."
        return domain_matches?(domain, base_domain)
      end

      false
    end
  end

  # Instance methods for inclusion in controllers
  def authorized_user?
    return true unless SplatAuthorization.oidc_configured?  # No auth required unless OIDC configured
    return false unless authenticated?  # Must be authenticated first

    # Check if user's email is in allowlist
    email = current_user_email
    return false unless email.present?

    SplatAuthorization.authorized?(email)
  end

  def oidc_configured?
    SplatAuthorization.oidc_configured?
  end
end
