# frozen_string_literal: true

class ProjectsController < ApplicationController
  before_action :set_project, only: [:show, :edit, :update, :destroy]

  # Sparkline + throughput/latency bundle. Separate cache entry from the counts
  # below, and a far longer TTL, because it's the expensive half of the page.
  INDEX_PERF_TTL = 5.minutes
  INDEX_SPARKLINE_BUCKETS = 24

  def index
    @projects = Project.ordered
    # Hour-aligned, because that's the granularity Event.hourly_volume caches
    # at — and it gives the tooltips round labels ("08:00") instead of whatever
    # minute the page happened to be loaded on.
    current_hour = Analytics::Histogram.hour_bucket(Time.current)
    @sparkline_range = (current_hour - (INDEX_SPARKLINE_BUCKETS - 1).hours)..(current_hour + 1.hour)

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
    counts = Rails.cache.fetch("projects_index_counts/v5", expires_in: 30.seconds, race_condition_ttl: 10.seconds) do
      {
        open_issues: Issue.open.group(:project_id).count,
        # Issues first seen today separates "this is new breakage" from "the
        # same 600k-event flood as yesterday" — the open count alone can't.
        new_issues: Issue.where(first_seen: 24.hours.ago..Time.current).group(:project_id).count,
        last_error: Issue.group(:project_id).maximum(:last_seen),
        # cron_monitors is a handful of rows per project in the primary DB, so
        # this grouped count is free next to everything else on this page.
        monitors: CronMonitor.group(:project_id, :state).count,
        last_transaction: @projects.each_with_object({}) do |project, latest|
          timestamp = Transaction.where(project_id: project.id).maximum(:timestamp)
          latest[project.id] = timestamp if timestamp
        end
      }
    end
    @open_issue_counts = counts[:open_issues]
    @new_issue_counts = counts[:new_issues]
    @last_error_at = counts[:last_error]
    @last_transaction_at = counts[:last_transaction]
    @monitor_health = monitor_health(counts[:monitors])

    perf = Rails.cache.fetch(
      "projects_index_perf/v1/#{@projects.maximum(:id)}",
      expires_in: INDEX_PERF_TTL, race_condition_ttl: 15.seconds
    ) do
      range = 24.hours.ago..Time.current
      @projects.each_with_object({}) do |project, out|
        # Throughput and error rate come off transaction_hourly_stats and p95
        # off transaction_histograms — both pre-aggregated, so this is a seek
        # per project rather than a scan of raw transactions.
        row = Transaction.total_and_error_count_in_range(time_range: range, project_id: project.id)
        out[project.id] = {
          transaction_count: row[:total],
          error_rate: row[:total].zero? ? nil : (row[:errors].to_f / row[:total] * 100).round(2),
          p95: (Transaction.percentiles(range, project_id: project.id)[:p95] if row[:total].positive?),
          # Per-hour cached (see Event.hourly_volume): a recompute scans the
          # settling window, not all 24 hours, so this stays affordable on a
          # project taking hundreds of thousands of events a day.
          events_by_hour: Event.hourly_volume(
            project_id: project.id, hours: INDEX_SPARKLINE_BUCKETS
          )
        }
      end
    end
    @project_perf = perf
  end

  def reorder
    Project.reorder_by_slugs!(params[:slugs])
    head :no_content
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

    # Hour-aligned, matching the index: it's the granularity
    # Event.hourly_volume caches at, and it lines every chart on the page up on
    # the same boundaries instead of on whatever minute the page was loaded.
    @sparkline_buckets = 24
    current_hour = Analytics::Histogram.hour_bucket(Time.current)
    @sparkline_range = (current_hour - (@sparkline_buckets - 1).hours)..(current_hour + 1.hour)

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
        # Per-hour cached, same as the index — see Event.hourly_volume.
        events_by_hour: Event.hourly_volume(
          project_id: @project.id, hours: @sparkline_buckets
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

  # Collapse the (project_id, state) grouped count into one verdict per
  # project. `unknown` means "no schedule to evaluate against" (see
  # CronMonitor), so it's neither healthy nor a failure — it's excluded from
  # both counts rather than shown as a scary red number.
  def monitor_health(grouped)
    grouped.each_with_object({}) do |((project_id, state), count), out|
      health = out[project_id] ||= {ok: 0, failing: 0, unknown: 0}
      case state
      when "ok" then health[:ok] += count
      when "unknown" then health[:unknown] += count
      else health[:failing] += count
      end
    end
  end

  def set_project
    @project = Project.find_by!(slug: params[:slug])
  end

  def project_params
    params.require(:project).permit(:name, :forward_dsns_text)
  end
end
