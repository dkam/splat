# frozen_string_literal: true

# Service for authenticating DSN (Data Source Name) requests
# Follows Sentry protocol for extracting and validating authentication credentials.
#
# Two auth modes:
#
# 1. Direct client (default): Sentry-protocol DSN auth. The client supplies its
#    project's public_key via X-Sentry-Auth / Authorization / ?sentry_key=, and
#    we look up the project and require the stored public_key to match.
#
# 2. Trusted forwarder (when SPLAT_FORWARDER_TOKEN is set and the request
#    carries a matching X-Splat-Forwarder-Token header): we trust the upstream
#    Splat's identification of the project. The public_key in the inbound
#    X-Sentry-Auth becomes the *seed* for an auto-created project if the slug
#    is unknown, but we do NOT require it to match an existing project's key.
#    This breaks the cross-instance key-sync requirement that direct-mode DSN
#    auth would otherwise impose on a forwarding chain.
class DsnAuthenticationService
  class AuthenticationError < StandardError; end

  # Header used by EnvelopeForwarder to declare a trusted-forwarder hop.
  FORWARDER_TOKEN_HEADER = 'X-Splat-Forwarder-Token'

  # Slug shape required for forwarder-driven auto-create: starts with a
  # lowercase letter, only lowercase letters/digits/hyphens/underscores;
  # max 64 chars. Leading-letter rule prevents a numeric project_id from
  # shadowing the id-based lookup with a slug-shaped project.
  AUTO_CREATE_SLUG = /\A[a-z][a-z0-9_-]{0,63}\z/.freeze

  # Supported authentication methods per Sentry protocol
  # 1. Query parameter: ?sentry_key=public_key
  # 2. X-Sentry-Auth header: Sentry sentry_key=public_key, sentry_version=7
  # 3. Authorization header (Bearer token or custom format)
  def self.authenticate(request, project_id)
    public_key = extract_public_key(request)

    if trusted_forwarder?(request)
      authenticate_via_forwarder(project_id, public_key)
    else
      validate_project_access!(public_key, project_id)
    end
  end

  # Extract public key from various authentication sources
  def self.extract_public_key(request)
    # Method 1: Query parameter (highest priority for simplicity).
    # GlitchTip SDKs send ?glitchtip_key=; Sentry SDKs send ?sentry_key=.
    if request.GET.key?('sentry_key')
      return request.GET['sentry_key']
    elsif request.GET.key?('glitchtip_key')
      return request.GET['glitchtip_key']
    end

    # Method 2: X-Sentry-Auth header
    auth_header = request.headers['X-Sentry-Auth']
    if auth_header
      key_from_header = parse_sentry_auth_header(auth_header)
      return key_from_header if key_from_header
    end

    # Method 3: Authorization header
    authorization_header = request.headers['Authorization']
    if authorization_header
      key_from_auth = parse_authorization_header(authorization_header)
      return key_from_auth if key_from_auth
    end

    raise AuthenticationError, 'Unable to find authentication information'
  end

  # Whether the request carries a valid trusted-forwarder token. Constant-time
  # comparison; returns false unless ENV configures a token and the inbound
  # header matches it exactly.
  def self.trusted_forwarder?(request)
    expected = ENV['SPLAT_FORWARDER_TOKEN']
    return false if expected.blank?

    provided = request.headers[FORWARDER_TOKEN_HEADER]
    return false if provided.blank?

    ActiveSupport::SecurityUtils.secure_compare(expected.to_s, provided.to_s)
  end

  private

  # Parse Sentry authentication header format:
  # "Sentry sentry_key=public_key, sentry_version=7, sentry_client=ruby-sdk/1.0.0"
  def self.parse_sentry_auth_header(header)
    return nil unless header.start_with?('Sentry ')

    # Extract sentry_key from header
    match = header.match(/sentry_key=([^,\s]+)/)
    match&.[](1)&.strip
  end

  # Parse Authorization header (supports multiple formats)
  def self.parse_authorization_header(header)
    # Format 1: Bearer token
    if header.start_with?('Bearer ')
      return header[7..-1] # Remove "Bearer " prefix
    end

    # Format 2: Custom "Sentry" format
    if header.start_with?('Sentry ')
      return parse_sentry_auth_header(header)
    end

    nil
  end

  # Validate that the public key has access to the specified project. Used
  # for direct (un-forwarded) client requests.
  def self.validate_project_access!(public_key, project_id)
    return nil if public_key.blank? || project_id.blank?

    project = Project.find_by_project_id(project_id)
    raise AuthenticationError, 'Invalid project ID' unless project

    unless project.public_key == public_key
      Rails.logger.warn "DSN authentication failed: public_key '#{public_key}' does not match project '#{project_id}'"
      raise AuthenticationError, 'Invalid DSN credentials'
    end

    project
  end

  # Forwarder-trusted path: look the project up by id/slug; auto-create if
  # missing using the inbound public_key as the seed for the new project's
  # key. We do not require the stored public_key to match the inbound key —
  # the trust signal is the verified forwarder token, not the per-project
  # DSN secret (which need not be in sync across instances).
  def self.authenticate_via_forwarder(project_id, public_key)
    raise AuthenticationError, 'Missing project ID for forwarded envelope' if project_id.blank?

    project = Project.find_by_project_id(project_id)
    return project if project

    project = auto_create_project(project_id, public_key)
    raise AuthenticationError, "Cannot auto-create project for slug '#{project_id}'" unless project

    project
  end

  def self.auto_create_project(slug, public_key)
    return nil unless slug.is_a?(String) && slug.match?(AUTO_CREATE_SLUG)

    attrs = { name: slug.titleize, slug: slug }
    attrs[:public_key] = public_key if public_key.present?

    project = Project.create!(attrs)
    Rails.logger.info "[DsnAuthenticationService] auto-created project slug=#{slug} via trusted forwarder"
    project
  rescue ActiveRecord::RecordNotUnique
    # Another concurrent forward created it; refetch.
    Project.find_by(slug: slug)
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn "[DsnAuthenticationService] failed to auto-create project slug=#{slug}: #{e.message}"
    nil
  end
end
