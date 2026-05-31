# frozen_string_literal: true

# Service for authenticating DSN (Data Source Name) requests
# Follows Sentry protocol for extracting and validating authentication credentials
class DsnAuthenticationService
  class AuthenticationError < StandardError; end

  # Supported authentication methods per Sentry protocol
  # 1. Query parameter: ?sentry_key=public_key
  # 2. X-Sentry-Auth header: Sentry sentry_key=public_key, sentry_version=7
  # 3. Authorization header (Bearer token or custom format)
  def self.authenticate(request, project_id)
    public_key = extract_public_key(request)
    validate_project_access!(public_key, project_id)
  end

  # Extract public key from various authentication sources
  def self.extract_public_key(request)
    # Method 1: Query parameter (highest priority for simplicity)
    if request.GET.key?('sentry_key')
      return request.GET['sentry_key']
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

  # Validate that the public key has access to the specified project
  def self.validate_project_access!(public_key, project_id)
    return nil if public_key.blank? || project_id.blank?

    project = Project.find_by_project_id(project_id) ||
              auto_create_project(project_id, public_key)
    raise AuthenticationError, 'Invalid project ID' unless project

    unless project.public_key == public_key
      Rails.logger.warn "DSN authentication failed: public_key '#{public_key}' does not match project '#{project_id}'"
      raise AuthenticationError, 'Invalid DSN credentials'
    end

    project
  end

  # Slug shape required for auto-create: starts with a lowercase letter, only
  # lowercase letters, digits, hyphens, underscores; max 64 chars. Must start
  # with a letter so a stray numeric project_id can't accidentally spawn a
  # slug-shaped project that shadows the numeric-id lookup.
  AUTO_CREATE_SLUG = /\A[a-z][a-z0-9_-]{0,63}\z/.freeze

  # Auto-create a project when the inbound DSN points at an unknown slug,
  # gated by SPLAT_AUTO_CREATE_SLUGS env. The env value is a comma-separated
  # list of allowed slugs; the literal "*" allows any slug that matches the
  # shape regex above. Unset/empty disables auto-create entirely.
  def self.auto_create_project(slug, public_key)
    return nil unless slug.is_a?(String) && slug.match?(AUTO_CREATE_SLUG)
    return nil unless auto_create_allowed?(slug)

    project = Project.create!(
      name: slug.titleize,
      slug: slug,
      public_key: public_key
    )
    Rails.logger.warn "[DsnAuthenticationService] auto-created project slug=#{slug} (SPLAT_AUTO_CREATE_SLUGS)"
    project
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    # Another request created it concurrently, or public_key collides with an
    # existing project's key. Fall back to a lookup — the caller will then
    # re-check the public_key match and reject if it doesn't line up.
    Project.find_by(slug: slug)
  end

  def self.auto_create_allowed?(slug)
    allowed = ENV['SPLAT_AUTO_CREATE_SLUGS'].to_s.split(',').map(&:strip).reject(&:empty?)
    return false if allowed.empty?
    return true if allowed.include?('*')
    allowed.include?(slug)
  end
end