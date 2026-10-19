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

  # The one clock: every row of the project on one time axis (see
  # ProjectTimeline). ?window= picks 1h to 30d; without it the page opens at
  # 24h, or 7d for a project with too little in the last day to draw.
  def show
    @timeline = ProjectTimeline.for(@project, window: params[:window])
    @queue_depth = queue_depth
    @last_event_at = @project.issues.maximum(:last_seen)
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
    params.require(:project).permit(:name, :forward_dsns_text, :source_url_template)
  end
end
