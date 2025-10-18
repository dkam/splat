# frozen_string_literal: true

class Api::EnvelopesController < ApplicationController
  skip_before_action :verify_authenticity_token

  # POST /api/:project_id/envelope/
  def create
    project = find_project
    return head :not_found unless project

    Sentry::EnvelopeProcessor.new(request.body.read, project).process

    # Always return 200 OK to avoid client retries
    head :ok
  end

  private

  def find_project
    Project.find_by(id: params[:project_id]) ||
      Project.find_by(slug: params[:project_id])
  end
end
