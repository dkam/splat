# frozen_string_literal: true

class LogsController < ApplicationController
  include Pagy::Method
  include TimeWindowParam

  before_action :set_project

  # Logs live in day files (Logs::DayFiles), so scope by project_id rather
  # than a cross-DB association, and read through Logs::Reader, which runs the
  # same relation on each file and merges the pages.
  def index
    @level = params[:level].presence
    @trace_id = params[:trace_id].presence
    @environment = params[:environment].presence
    @release = params[:release].presence
    @service = params[:service].presence
    @source = params[:source].presence
    @query = params[:q].presence
    # ?from=&to=, from a click on the project timeline's Logs row.
    @window = time_window_param

    # Countless: no COUNT(*) across the files — an append-only feed only needs
    # prev/next, not a total page count.
    logs = Logs::Reader::Page.new(within: @window) { logs_relation }
    @pagy, @logs = pagy(:countless, logs, limit: 50)

    # Filter-dropdown values, maintained at ingest in the facets table (primary
    # DB). Replaces three DISTINCT scans over the ~1M-row logs table that used to
    # dominate this page's load time — these are covered lookups on a tiny table.
    @environments = Facet.values_for(@project.id, :log, :environment)
    @sources = Facet.values_for(@project.id, :log, :source)
    @services = Facet.values_for(@project.id, :log, :service)
    # Releases sort lexically like every other facet, which puts "1.10.0" before
    # "1.9.0". Newest-first is what you want in a deploy dropdown, and the list
    # is small enough to reverse here rather than teach Facet an ordering.
    @releases = Facet.values_for(@project.id, :log, :release).reverse
  end

  # By log_id. A numeric id is a link from before day files, into the legacy
  # database, the only place an id alone still names one log.
  def show
    scope = ->(logs) { logs.where(project_id: @project.id) }
    @log = if params[:id].match?(/\A\d+\z/)
      Logs::Reader.find_in_legacy(params[:id], &scope)
    else
      Logs::Reader.find_by_log_id(params[:id], &scope)
    end
    raise ActiveRecord::RecordNotFound, "Couldn't find Log #{params[:id]}" unless @log

    @related = related_transaction
  end

  private

  # Built inside each day file's shard (see Logs::Reader).
  def logs_relation
    logs = Log.where(project_id: @project.id)
    logs = logs.by_level(@level) if @level && Log.levels.key?(@level)
    logs = logs.for_trace(@trace_id) if @trace_id
    logs = logs.by_environment(@environment) if @environment
    logs = logs.by_release(@release) if @release
    logs = logs.by_service(@service) if @service
    logs = logs.by_source(@source) if @source
    logs = logs.where(timestamp: @window) if @window
    logs = logs.search_text(@query, within: @window) if @query
    logs
  end

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
