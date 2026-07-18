# frozen_string_literal: true

class MonitorsController < ApplicationController
  before_action :set_project

  def index
    @monitors = @project.cron_monitors.by_slug
  end

  private

  def set_project
    # Accept both slug (e.g., "booko") and ID (e.g., "1")
    @project = Project.find_by(slug: params[:project_slug]) || Project.find(params[:project_slug])
  end
end
