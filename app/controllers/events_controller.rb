# frozen_string_literal: true

class EventsController < ApplicationController
  include Pagy::Backend

  before_action :set_project
  before_action :set_event, only: [:show, :destroy]

  def show
    @issue = @event.issue
  end

  def destroy
    issue = @event.issue
    @event.destroy
    if issue
      redirect_to project_issue_path(@project.slug, issue), notice: "Event deleted"
    else
      redirect_to project_path(@project.slug), notice: "Event deleted"
    end
  end

  private

  def set_project
    @project = Project.find_by!(slug: params[:project_slug])
  end

  def set_event
    @event = @project.events.find(params[:id])
  end
end
