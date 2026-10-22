# frozen_string_literal: true

class MonitorsController < ApplicationController
  include TimeWindowParam

  # A week, not the project page's day: a weekly job runs once in it, and
  # each daily one seven times.
  DEFAULT_WINDOW = "7d"

  before_action :set_project

  # The project's monitors on its clock (MonitorsTimeline). ?window= picks the
  # window ending now; ?from=&to= (TimeWindowParam), one a timeline opened.
  def index
    @window_key = params[:window].presence_in(ProjectTimeline::WINDOWS.keys) || DEFAULT_WINDOW
    @window = time_window_param
    @timeline = MonitorsTimeline.new(@project, window: @window_key, range: @window)
  end

  private

  def set_project
    # Accept both slug (e.g., "booko") and ID (e.g., "1")
    @project = Project.find_by(slug: params[:project_slug]) || Project.find(params[:project_slug])
  end
end
