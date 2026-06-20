# frozen_string_literal: true

# Single-transaction detail only. The grouped surface — endpoints,
# slow lists, N+1 worklist — moved to EndpointsController.
class TransactionsController < ApplicationController
  before_action :set_project
  before_action :set_transaction, only: [:show]

  def show
    @spans = Span.for_transaction(
      @transaction.transaction_id,
      project_id: @project.id,
      near_timestamp: @transaction.timestamp
    )

    respond_to do |format|
      format.html
      format.json { render json: transaction_data }
      format.csv { send_data transaction_csv, filename: "transaction_#{@transaction.transaction_id}.csv" }
    end
  end

  private

  def set_project
    @project = Project.find_by!(slug: params[:project_slug])
  end

  def set_transaction
    @transaction = @project.transactions.find(params[:id])
  end

  def transaction_data
    {
      id: @transaction.id,
      transaction_id: @transaction.transaction_id,
      timestamp: @transaction.timestamp,
      transaction_name: @transaction.transaction_name,
      op: @transaction.op,
      duration: @transaction.duration,
      db_time: @transaction.db_time,
      view_time: @transaction.view_time,
      environment: @transaction.environment,
      release: @transaction.release,
      server_name: @transaction.server_name,
      http_method: @transaction.http_method,
      http_status: @transaction.http_status,
      http_url: @transaction.http_url,
      tags: @transaction.tags,
      measurements: @transaction.measurements,
      query_analysis: {
        total_queries: @transaction.query_count,
        unique_patterns: @transaction.unique_query_patterns,
        potential_n_plus_one: @transaction.potential_n_plus_one_queries,
        query_patterns: @transaction.query_patterns
      },
      performance_metrics: {
        slow?: @transaction.slow?,
        http_success?: @transaction.http_success?,
        http_error?: @transaction.http_error?,
        db_overhead_percentage: @transaction.db_overhead_percentage,
        view_overhead_percentage: @transaction.view_overhead_percentage,
        other_time: @transaction.other_time
      },
      controller_info: {
        controller_action: @transaction.controller_action,
        controller: @transaction.controller,
        action: @transaction.action
      },
      created_at: @transaction.created_at,
      updated_at: @transaction.updated_at
    }
  end

  def transaction_csv
    require "csv"

    CSV.generate(headers: true) do |csv|
      csv << [
        "Transaction ID", "Timestamp", "Transaction Name", "Operation",
        "Duration (ms)", "DB Time (ms)", "View Time (ms)",
        "Environment", "Release", "Server Name",
        "HTTP Method", "HTTP Status", "HTTP URL",
        "Total Queries", "Unique Query Patterns", "N+1 Patterns",
        "DB Overhead %", "View Overhead %", "Other Time (ms)",
        "Controller", "Action", "Created At"
      ]

      csv << [
        @transaction.transaction_id, @transaction.timestamp, @transaction.transaction_name, @transaction.op,
        @transaction.duration, @transaction.db_time, @transaction.view_time,
        @transaction.environment, @transaction.release, @transaction.server_name,
        @transaction.http_method, @transaction.http_status, @transaction.http_url,
        @transaction.query_count, @transaction.unique_query_patterns, @transaction.potential_n_plus_one_queries.size,
        @transaction.db_overhead_percentage, @transaction.view_overhead_percentage, @transaction.other_time,
        @transaction.controller, @transaction.action, @transaction.created_at
      ]

      if @transaction.query_patterns.any?
        csv << []
        csv << ["Query Patterns Details"]
        csv << ["Pattern", "Count", "Example Query"]
        @transaction.query_patterns.each do |pattern, data|
          csv << [pattern, data[:count], data[:examples]&.first&.truncate(200) || "N/A"]
        end
      end

      if @transaction.has_n_plus_one_queries?
        csv << []
        csv << ["N+1 Query Warnings"]
        csv << ["Pattern"]
        @transaction.potential_n_plus_one_queries.each { |pattern| csv << [pattern] }
      end

      if @transaction.tags.present? && @transaction.tags.any?
        csv << []
        csv << ["Tags"]
        csv << ["Key", "Value"]
        @transaction.tags.each { |key, value| csv << [key, value] }
      end
    end
  end
end
