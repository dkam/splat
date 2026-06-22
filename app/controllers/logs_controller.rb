# frozen_string_literal: true

class LogsController < ApplicationController
  include Pagy::Backend

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
    logs = logs.search_body(@query) if @query

    @pagy, @logs = pagy(logs, limit: 50)

    # Distinct facets for the filter dropdowns (cheap, bounded result sets).
    @environments = Log.where(project_id: @project.id).distinct.pluck(:environment).compact.sort
  end

  def show
    @log = Log.where(project_id: @project.id).find(params[:id])
    @related = related_transaction
  end

  private

  def set_project
    @project = Project.find_by(slug: params[:project_slug]) || Project.find(params[:project_slug])
  end

  # If the log carries a trace_id, try to find the matching transaction so the
  # detail view can link log → trace. trace_id lives on spans, so resolve the
  # span's transaction_id (a UUID) to the Transaction record (numeric PK the
  # show route expects).
  def related_transaction
    return nil if @log.trace_id.blank?
    txn_uuid = Span.where(project_id: @project.id, trace_id: @log.trace_id)
      .where.not(transaction_id: nil)
      .limit(1)
      .pick(:transaction_id)
    return nil unless txn_uuid
    Transaction.find_by(project_id: @project.id, transaction_id: txn_uuid)
  end
end
