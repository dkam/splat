# frozen_string_literal: true

class EventsController < ApplicationController
  include Pagy::Method

  before_action :set_project
  before_action :set_event, only: [:show, :destroy]

  def show
    @issue = @event.issue
    @related_transaction = @event.related_transaction

    # trace_id ties an error to the rest of its request: the transaction it was
    # thrown in (above) and every log line from the same trace. .presence guards
    # a blank trace_id from matching every untraced log in the project; the count
    # rides index_logs_on_project_id_and_trace_id.
    @trace_id = @event.trace_id.presence
    @trace_log_count = @trace_id ? Log.where(project_id: @project.id, trace_id: @trace_id).count : 0
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
