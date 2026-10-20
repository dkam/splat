# frozen_string_literal: true

class IssuesController < ApplicationController
  include Pagy::Method
  include TimeWindowParam

  SORTS = %w[recent busiest new].freeze

  before_action :set_project
  before_action :set_issue, only: [:show, :resolve, :resolve_in_next_release, :ignore, :reopen]

  # The tab's issues on the project page's clock (IssuesTimeline). Recent
  # lists every one, last seen first; busiest, those with events in the window,
  # most first; new, those first seen in it. ?from=&to= (TimeWindowParam) opens
  # it for a bucket clicked on a timeline, busiest first unless asked otherwise.
  def index
    @status = params[:status].presence_in(%w[resolved ignored]) || "open"
    @window_key = params[:window].presence_in(ProjectTimeline::WINDOWS.keys) || ProjectTimeline::DEFAULT_WINDOW
    @window = time_window_param
    @sort = params[:sort].presence_in(SORTS) || (@window ? "busiest" : "recent")

    # "Seen in", not "belongs to" — grouping spans environments, so an issue
    # can appear under staging and production both. Backed by issue_facets
    # (maintained at ingest), so this stays an indexed subquery rather than a
    # DISTINCT over events.
    @environment = params[:environment].presence

    @timeline = IssuesTimeline.new(@project, window: @window_key, range: @window, status: @status,
      environment: @environment)
    issues = case @sort
    when "busiest" then @timeline.issues.in_order_of(:id, @timeline.busiest_ids)
    when "new" then @timeline.issues.where(first_seen: @timeline.range).order(first_seen: :desc, id: :desc)
    else @timeline.issues.recent
    end

    @pagy, @issues = pagy(issues, limit: 25)
    @rows = @timeline.rows(@issues)
    @burst_threshold = Setting.instance.burst_threshold

    counts_by_status = Rails.cache.fetch("project_#{@project.id}_issue_counts", expires_in: 30.seconds) do
      @project.issues.group(:status).count
    end
    @open_count = counts_by_status["open"] || 0
    @resolved_count = counts_by_status["resolved"] || 0
    @ignored_count = counts_by_status["ignored"] || 0

    # Dropdown options, and the per-row chips for the page of issues on screen
    # (one query for the page, not one per row). Both are pointless on a project
    # that only ever reports one environment — no dropdown, and a chip repeating
    # "production" on every row — so a single-environment project skips the
    # second query entirely.
    @environments = IssueFacet.values_for(@project.id, :environment)
    @issue_environments = if @environments.many?
      IssueFacet.values_by_issue(@issues.map(&:id), :environment)
    else
      {}
    end
    @issue_users = IssueFacet.counts_by_issue(@issues.map(&:id), :user)
  end

  def show
    @events = @issue.events.recent.limit(50)
    @affected_users = @issue.affected_users_count

    @spark_range = 7.days.ago..Time.current
    @spark_buckets = 168
    @spark_counts = Event.event_counts_by_bucket(
      issue_ids: [@issue.id],
      time_range: @spark_range,
      buckets: @spark_buckets,
      project_id: @project.id
    )[@issue.id]
    @deploy_markers = @project.releases
      .where(first_seen_at: @spark_range)
      .pluck(:first_seen_at)
  end

  # The status actions are triggered from two places — the issue page and the
  # rows on the issues list — so they return to whichever one asked. Coming from
  # the list, that redirect lands back on the URL the browser is already showing
  # (status tab, environment filter and page intact), which Turbo treats as a
  # page refresh and morphs: the row leaves the tab it no longer belongs to and
  # the tab counts move, without losing scroll position.
  def resolve
    @issue.resolved!
    redirect_back_or_to project_issue_path(@project.slug, @issue),
      allow_other_host: false, notice: "Issue marked as resolved"
  end

  def resolve_in_next_release
    @issue.resolve_in_next_release!
    redirect_back_or_to project_issue_path(@project.slug, @issue),
      allow_other_host: false, notice: "Resolved in the release after #{@issue.resolved_in_release}"
  rescue Issue::NoRelease
    redirect_back_or_to project_issue_path(@project.slug, @issue),
      allow_other_host: false, alert: "No release seen for #{@project.name} yet, so there's no next one to resolve in"
  end

  def ignore
    @issue.ignored!
    redirect_back_or_to project_issue_path(@project.slug, @issue),
      allow_other_host: false, notice: "Issue ignored"
  end

  def reopen
    @issue.open!
    redirect_back_or_to project_issue_path(@project.slug, @issue),
      allow_other_host: false, notice: "Issue reopened"
  end

  private

  def set_project
    # Accept both slug (e.g., "booko") and ID (e.g., "1")
    @project = Project.find_by(slug: params[:project_slug]) || Project.find(params[:project_slug])
  end

  def set_issue
    @issue = @project.issues.find(params[:id])
  end
end
