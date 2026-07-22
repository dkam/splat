# frozen_string_literal: true

class IssuesController < ApplicationController
  include Pagy::Method

  before_action :set_project
  before_action :set_issue, only: [:show, :resolve, :ignore, :reopen]

  def index
    @status = params[:status] || "open"
    issues = case @status
    when "resolved"
      @project.issues.resolved
    when "ignored"
      @project.issues.ignored
    else
      @project.issues.open
    end.recent

    # "Seen in", not "belongs to" — grouping spans environments, so an issue
    # can appear under staging and production both. Backed by issue_facets
    # (maintained at ingest), so this stays an indexed subquery rather than a
    # DISTINCT over events.
    @environment = params[:environment].presence
    issues = issues.seen_in_environment(@environment, project_id: @project.id) if @environment

    @pagy, @issues = pagy(issues, limit: 25)
    @burst_threshold = Setting.instance.burst_threshold

    counts_by_status = Rails.cache.fetch("project_#{@project.id}_issue_counts", expires_in: 30.seconds) do
      @project.issues.group(:status).count
    end
    @open_count = counts_by_status["open"] || 0
    @resolved_count = counts_by_status["resolved"] || 0
    @ignored_count = counts_by_status["ignored"] || 0

    @sparkline_buckets = 24
    @sparkline_range = 24.hours.ago..Time.current
    @sparklines = Event.event_counts_by_bucket(
      issue_ids: @issues.map(&:id),
      time_range: @sparkline_range,
      buckets: @sparkline_buckets,
      project_id: @project.id
    )
    @deploy_markers = @project.releases
      .where(first_seen_at: @sparkline_range)
      .pluck(:first_seen_at)

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
  end

  def show
    @events = @issue.events.recent.limit(50)

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

  def resolve
    @issue.resolved!
    redirect_to project_issue_path(@project.slug, @issue), notice: "Issue marked as resolved"
  end

  def ignore
    @issue.ignored!
    redirect_to project_issue_path(@project.slug, @issue), notice: "Issue ignored"
  end

  def reopen
    @issue.open!
    redirect_to project_issue_path(@project.slug, @issue), notice: "Issue reopened"
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
