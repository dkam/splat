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

    project = Project.find_by_project_id(project_id)
    raise AuthenticationError, 'Invalid project ID' unless project

    unless project.public_key == public_key
      Rails.logger.warn "DSN authentication failed: public_key '#{public_key}' does not match project '#{project_id}'"
      raise AuthenticationError, 'Invalid DSN credentials'
    end

    project
  end
end