# frozen_string_literal: true

class ProjectsController < ApplicationController
  before_action :set_project, only: [:show, :edit, :update, :destroy]

  def index
    @projects = Project.all.order(updated_at: :desc)

    # Only the issues-table aggregates here — the issues table is small and indexed.
    # Event.group(:project_id).count is a full-table scan over the (potentially huge)
    # events table and was hanging the index page. Per-project event totals and last
    # activity now come from the issues table (last_seen) which is cheap.
    counts = Rails.cache.fetch("projects_index_counts/v2", expires_in: 30.seconds, race_condition_ttl: 10.seconds) do
      {
        open_issues: Issue.open.group(:project_id).count,
        last_seen: Issue.group(:project_id).maximum(:last_seen)
      }
    end
    @open_issue_counts = counts[:open_issues]
    @last_event_at = counts[:last_seen]
  end

  # Show is a dashboard — six DuckLake aggregates per page load was beating
  # the columnar reads to death (especially on Docker volumes), and made the
  # whole app contend on the shared DuckLake connection. We now compute the
  # DuckLake-derived ivars once per 30s per project and stash them in Rails
  # cache. SQLite-backed lookups (recent_issues, recent_events) and the queue
  # depth stay live since they're cheap.
  SHOW_METRICS_TTL = 30.seconds

  def show
    @recent_issues = @project.open_issues.limit(5)
    @recent_events = @project.recent_events(limit: 5)
    @queue_depth = queue_depth
    @open_issue_count = Rails.cache.fetch("project_#{@project.id}_open_issue_count", expires_in: SHOW_METRICS_TTL) do
      @project.issues.open.count
    end

    @sparkline_buckets = 24
    @sparkline_range = 24.hours.ago..Time.current

    metrics = Rails.cache.fetch(
      "project_#{@project.id}_show_metrics/v3",
      expires_in: SHOW_METRICS_TTL,
      race_condition_ttl: 10.seconds
    ) do
      top_endpoints = @project.top_endpoints_by_impact(limit: 5)
      {
        top_endpoints: top_endpoints,
        event_count_24h: @project.event_count(24.hours.ago..Time.current),
        transaction_count_24h: @project.transaction_count(24.hours.ago..Time.current),
        p50_response_time: @project.p50_response_time,
        endpoint_sparklines: DuckLake::Transaction.p95_by_bucket(
          transaction_names: top_endpoints.map { |e| e["transaction_name"] },
          time_range: @sparkline_range, buckets: @sparkline_buckets,
          project_id: @project.id
        ),
        events_by_hour: DuckLake::Event.volume_by_bucket(
          time_range: @sparkline_range, buckets: @sparkline_buckets,
          project_id: @project.id
        ),
        transactions_by_hour: DuckLake::Transaction.volume_by_bucket(
          time_range: @sparkline_range, buckets: @sparkline_buckets,
          project_id: @project.id
        )
      }
    end

    @top_endpoints = metrics[:top_endpoints]
    @event_count_24h = metrics[:event_count_24h]
    @transaction_count_24h = metrics[:transaction_count_24h]
    @p50_response_time = metrics[:p50_response_time]
    @endpoint_sparklines = metrics[:endpoint_sparklines]
    @events_by_hour = metrics[:events_by_hour]
    @transactions_by_hour = metrics[:transactions_by_hour]

    # Issue sparklines depend on the live @recent_issues ids, so they're
    # cached separately keyed off the visible issue set. Cheap when warm.
    issue_ids = @recent_issues.map(&:id)
    @issue_sparklines = Rails.cache.fetch(
      "project_#{@project.id}_issue_sparklines/#{issue_ids.sort.join(',')}",
      expires_in: SHOW_METRICS_TTL
    ) do
      DuckLake::Event.event_counts_by_bucket(
        issue_ids: issue_ids,
        time_range: @sparkline_range,
        buckets: @sparkline_buckets,
        project_id: @project.id
      )
    end

    @deploy_markers = @project.releases
      .where(first_seen_at: @sparkline_range)
      .pluck(:first_seen_at)
  end

  def new
    @project = Project.new
  end

  def create
    @project = Project.new(project_params)

    if @project.save
      redirect_to project_path(@project.slug), notice: "Project created successfully"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @project.update(project_params)
      redirect_to project_path(@project.slug), notice: "Project updated successfully"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @project.destroy
    redirect_to root_path, notice: "Project deleted successfully"
  end

  private

  def set_project
    @project = Project.find_by!(slug: params[:slug])
  end

  def project_params
    params.require(:project).permit(:name)
  end
end
