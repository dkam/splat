# frozen_string_literal: true

class LogsController < ApplicationController
  include Pagy::Backend

  # How long the environment-filter facet is cached. A distinct scan over the
  # logs table is expensive; staleness here only delays a new environment
  # appearing in the dropdown.
  ENVIRONMENTS_TTL = 5.minutes

  before_action :set_project

  # Logs live on their own DB, so scope by project_id rather than a cross-DB
  # association.
  def index
    logs = Log.where(project_id: @project.id).recent

    @level = params[:level].presence
    @trace_id = params[:trace_id].presence
    @environment = params[:environment].presence
    @query = params[:q].presence

    logs = logs.by_level(@level) if @level && Log.levels.key?(@level)
    logs = logs.for_trace(@trace_id).reorder(timestamp: :desc) if @trace_id
    logs = logs.by_environment(@environment) if @environment
    logs = logs.search_text(@query) if @query

    # Countless: avoids a SELECT COUNT(*) over the ~1M-row logs table (~7s) —
    # an append-only feed only needs prev/next, not a total page count.
    @pagy, @logs = pagy_countless(logs, limit: 50)

    # Distinct environments for the filter dropdown. A DISTINCT over a
    # high-volume table is too costly to run on every page load, so cache it
    # briefly (same TTL pattern as the project show metrics) — a new
    # environment showing up a few minutes late in the dropdown is fine.
    @environments = Rails.cache.fetch("project_#{@project.id}_log_environments", expires_in: ENVIRONMENTS_TTL) do
      Log.where(project_id: @project.id).distinct.pluck(:environment).compact.sort
    end
  end

  def show
    @log = Log.where(project_id: @project.id).find(params[:id])
    @related = related_transaction
  end

  private

  def set_project
    @project = Project.find_by(slug: params[:project_slug]) || Project.find(params[:project_slug])
  end

  # If the log carries a trace_id, find the matching transaction so the detail
  # view can link log → trace. trace_id is promoted onto the transaction, so this
  # is a direct lookup (index: transactions on [project_id, trace_id]).
  def related_transaction
    return nil if @log.trace_id.blank?
    Transaction.find_by(project_id: @project.id, trace_id: @log.trace_id)
  end
end
