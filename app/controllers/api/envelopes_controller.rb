# frozen_string_literal: true

class Api::EnvelopesController < ApplicationController
  skip_before_action :verify_authenticity_token

  # POST /api/:project_id/envelope/
  def create
    project = authenticate_project!
    return head :not_found unless project

    Sentry::EnvelopeProcessor.new(request.body.read, project).process

    # Always return 200 OK to avoid client retries
    head :ok
  rescue DsnAuthenticationService::AuthenticationError => e
    Rails.logger.warn "DSN authentication failed: #{e.message}"
    head :unauthorized
  end

  private

  def authenticate_project!
    DsnAuthenticationService.authenticate(request, params[:project_id])
  end
end
