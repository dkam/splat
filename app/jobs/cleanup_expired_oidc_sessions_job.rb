class CleanupExpiredOidcSessionsJob < ApplicationJob
  queue_as :default

  def perform
    expired_count = OidcSession.cleanup_expired

    Rails.logger.info "Cleaned up #{expired_count} expired OIDC session mappings"

    expired_count
  end
end
