# frozen_string_literal: true

class EventsController < ApplicationController
  include Pagy::Backend

  before_action :set_project
  before_action :set_event, only: [:show, :destroy]

  def index
    events = @project.events.recent

    # Filter by issue if provided
    events = events.by_issue(params[:issue_id]) if params[:issue_id].present?

    # Filter by environment if provided
    events = events.by_environment(params[:environment]) if params[:environment].present?

    # Filter by exception type if provided
    events = events.by_exception_type(params[:exception_type]) if params[:exception_type].present?

    @pagy, @events = pagy(events, limit: 25)

    # Get unique values for filters
    @environments = @project.events.pluck(:environment).compact.uniq.sort
    @exception_types = @project.events.pluck(:exception_type).compact.uniq.sort
  end

  def show
    @issue = @event.issue
  end

  def destroy
    @event.destroy
    redirect_to project_events_path(@project.slug), notice: "Event deleted"
  end

  private

  def set_project
    @project = Project.find_by!(slug: params[:project_slug])
  end

  def set_event
    @event = @project.events.find(params[:id])
  end
end
