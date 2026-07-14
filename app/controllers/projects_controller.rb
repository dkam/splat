# frozen_string_literal: true

class ProjectsController < ApplicationController
  before_action :set_project, only: [:show, :edit, :update, :destroy]

  def index
    @projects = Project.all.order(updated_at: :desc)

    # Last error (issues.last_seen) and last transaction (transactions.timestamp)
    # are surfaced separately so a project sending only performance data still
    # reads as active. The last-transaction MAX must be one query per project,
    # not Transaction.group(:project_id).maximum(:timestamp): SQLite has no
    # loose index scan, so the grouped form walks the entire (project_id,
    # timestamp) index (~9s at 260k rows), while MAX with an equality prefix on
    # that index is a single seek per project. (Events are excluded —
    # Event.group(:project_id) is a full scan over a potentially huge table and
    # was hanging the page; the issues table covers error recency.) Transactions
    # live in a separate DB, hence separate queries rather than a join.
    counts = Rails.cache.fetch("projects_index_counts/v4", expires_in: 30.seconds, race_condition_ttl: 10.seconds) do
      {
        open_issues: Issue.open.group(:project_id).count,
        last_error: Issue.group(:project_id).maximum(:last_seen),
        last_transaction: @projects.each_with_object({}) do |project, latest|
          timestamp = Transaction.where(project_id: project.id).maximum(:timestamp)
          latest[project.id] = timestamp if timestamp
        end
      }
    end
    @open_issue_counts = counts[:open_issues]
    @last_error_at = counts[:last_error]
    @last_transaction_at = counts[:last_transaction]
  end

  # Show is a dashboard — the metrics bundle runs a handful of aggregate
  # queries (hourly stats, histograms, event counts) per page load, so it's
  # computed once per cache window per project and stashed in Rails cache.
  # Row lookups (recent_issues, recent_events) and the queue depth stay live
  # since they're cheap.
  #
  # TTL is generous (5 min) because a cold miss costs seconds on a busy
  # instance; the data is for human eyeballs on a dashboard, freshness within
  # 5 minutes is fine.
  SHOW_METRICS_TTL = 5.minutes

  def show
    @recent_issues = @project.open_issues.limit(5)
    @recent_events = @project.recent_events(limit: 5)
    @queue_depth = queue_depth
    @open_issue_count = Rails.cache.fetch("project_#{@project.id}_open_issue_count", expires_in: SHOW_METRICS_TTL) do
      @project.issues.open.count
    end
    @logs_count_24h = Rails.cache.fetch("project_#{@project.id}_logs_count_24h", expires_in: SHOW_METRICS_TTL) do
      Log.where(project_id: @project.id).where(timestamp: 24.hours.ago..Time.current).count
    end

    @sparkline_buckets = 24
    @sparkline_range = 24.hours.ago..Time.current

    metrics = Rails.cache.fetch(
      "project_#{@project.id}_show_metrics/v4",
      expires_in: SHOW_METRICS_TTL,
      race_condition_ttl: 10.seconds
    ) do
      top_endpoints = @project.top_endpoints_by_impact(limit: 5)
      {
        top_endpoints: top_endpoints,
        event_count_24h: @project.event_count(24.hours.ago..Time.current),
        transaction_count_24h: @project.transaction_count(24.hours.ago..Time.current),
        p50_response_time: @project.p50_response_time,
        # error_rate moved into the cached bundle so it isn't recomputed
        # multiple times in the view (it was previously called 3x in
        # show.html.erb's CSS-class ternary).
        error_rate: @project.error_rate,
        endpoint_sparklines: Transaction.p95_by_bucket(
          transaction_names: top_endpoints.map { |e| e["transaction_name"] },
          time_range: @sparkline_range, buckets: @sparkline_buckets,
          project_id: @project.id
        ),
        events_by_hour: Event.volume_by_bucket(
          time_range: @sparkline_range, buckets: @sparkline_buckets,
          project_id: @project.id
        ),
        transactions_by_hour: Transaction.volume_by_bucket(
          time_range: @sparkline_range, buckets: @sparkline_buckets,
          project_id: @project.id
        )
      }
    end

    @top_endpoints = metrics[:top_endpoints]
    @event_count_24h = metrics[:event_count_24h]
    @transaction_count_24h = metrics[:transaction_count_24h]
    @p50_response_time = metrics[:p50_response_time]
    @error_rate = metrics[:error_rate]
    @endpoint_sparklines = metrics[:endpoint_sparklines]
    @events_by_hour = metrics[:events_by_hour]
    @transactions_by_hour = metrics[:transactions_by_hour]

    # Issue sparklines depend on the live @recent_issues ids, so they're
    # cached separately keyed off the visible issue set. Cheap when warm.
    issue_ids = @recent_issues.map(&:id)
    @issue_sparklines = Rails.cache.fetch(
      "project_#{@project.id}_issue_sparklines/#{issue_ids.sort.join(",")}",
      expires_in: SHOW_METRICS_TTL
    ) do
      Event.event_counts_by_bucket(
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
    params.require(:project).permit(:name, :forward_dsns_text)
  end
end
