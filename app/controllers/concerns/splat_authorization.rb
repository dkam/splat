# frozen_string_literal: true

# Authorization and user access management for Splat
# Handles email allowlist for user access control
module SplatAuthorization
  extend ActiveSupport::Concern

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

    # Check if OIDC is configured and ready
    def oidc_configured?
      ENV["OIDC_CLIENT_ID"].present? &&
        ENV["OIDC_CLIENT_SECRET"].present? &&
        ENV["OIDC_DISCOVERY_URL"].present?
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
        base_domain = allowed[2..-1]  # Remove "*."
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