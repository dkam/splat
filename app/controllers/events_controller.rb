# frozen_string_literal: true

class EventsController < ApplicationController
  include Pagy::Method
  include TimeWindowParam

  before_action :set_project
  before_action :set_event, only: [:show, :destroy]

  # What ?status= accepts: it's how the timeline's folded ignored and resolved
  # rows list their events.
  ISSUE_STATUSES = Issue.statuses.keys.freeze

  # A window's events, newest first: what a click on the project timeline's
  # Events row, or on an issue's row, opens. ?from=&to= (TimeWindowParam),
  # the last 24 hours without them; ?issue_id= narrows it to one issue and
  # ?status= to the issues in one status.
  def index
    @window = time_window_param || (24.hours.ago.utc...Time.current.utc)
    scope = @project.events.where(timestamp: @window)

    @issue = @project.issues.find_by(id: params[:issue_id]) if params[:issue_id].present?
    @status = params[:status].presence_in(ISSUE_STATUSES)
    scope = scope.where(issue_id: @issue.id) if @issue
    scope = scope.where(issue_id: @project.issues.where(status: @status).select(:id)) if @status

    counts = scope.where.not(issue_id: nil).group(:issue_id).count
    @total = counts.values.sum + scope.where(issue_id: nil).count
    @by_issue = counts.sort_by { |id, n| [-n, -id] }.first(12)
    @issues = @project.issues.where(id: @by_issue.map(&:first)).index_by(&:id)

    # Countless, as the logs are: a busy window can hold thousands, and the
    # count above already says how many.
    @pagy, @events = pagy(:countless, scope.order(timestamp: :desc, id: :desc).includes(:issue), limit: 50)
  end

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
