# frozen_string_literal: true

class TransactionsController < ApplicationController
  include Pagy::Backend

  before_action :set_project
  before_action :set_transaction, only: [:show]

  def index
    @time_range = params[:time_range] || "24h"
    time_ago = case @time_range
               when "1h" then 1.hour.ago
               when "6h" then 6.hours.ago
               when "24h" then 24.hours.ago
               when "7d" then 7.days.ago
               else 24.hours.ago
               end

    base_scope = @project.transactions.where("timestamp > ?", time_ago)
    base_scope = base_scope.where(environment: params[:environment]) if params[:environment].present?

    # Calculate stats
    durations = base_scope.pluck(:duration).sort
    if durations.any?
      @avg_duration = (durations.sum / durations.size.to_f).round
      @p95_duration = durations[(durations.size * 0.95).to_i] || 0
      @p99_duration = durations[(durations.size * 0.99).to_i] || 0
    else
      @avg_duration = @p95_duration = @p99_duration = 0
    end

    # Slow endpoints grouped by transaction_name
    @slow_endpoints = base_scope
      .group(:transaction_name)
      .select("transaction_name, AVG(duration) as avg_duration, COUNT(*) as count, MAX(duration) as max_duration")
      .order("avg_duration DESC")
      .limit(20)

    # Recent transactions
    @pagy, @transactions = pagy(base_scope.order(timestamp: :desc), limit: 50)

    # Available environments for filter
    @environments = @project.transactions.distinct.pluck(:environment).compact.sort
  end

  def show
    respond_to do |format|
      format.html
      format.json { render json: transaction_data }
      format.csv { send_data transaction_csv, filename: "transaction_#{@transaction.transaction_id}.csv" }
    end
  end

  def slow
    @time_range = params[:time_range] || "24h"
    time_ago = case @time_range
               when "1h" then 1.hour.ago
               when "6h" then 6.hours.ago
               when "24h" then 24.hours.ago
               when "7d" then 7.days.ago
               else 24.hours.ago
               end

    threshold = params[:threshold]&.to_i || 1000 # Default 1000ms = 1 second
    transactions = @project.transactions
      .where("timestamp > ?", time_ago)
      .where("duration > ?", threshold)
      .order(duration: :desc)

    @pagy, @transactions = pagy(transactions, limit: 50)
    @threshold = threshold
  end

  def by_endpoint
    @endpoint = params[:endpoint]
    @time_range = params[:time_range] || "24h"
    time_ago = case @time_range
               when "1h" then 1.hour.ago
               when "6h" then 6.hours.ago
               when "24h" then 24.hours.ago
               when "7d" then 7.days.ago
               else 24.hours.ago
               end

    transactions = @project.transactions
      .where(transaction_name: @endpoint)
      .where("timestamp > ?", time_ago)
      .order(timestamp: :desc)

    # Calculate endpoint-specific stats
    durations = transactions.pluck(:duration).sort
    if durations.any?
      @avg_duration = (durations.sum / durations.size.to_f).round
      @p95_duration = durations[(durations.size * 0.95).to_i] || 0
      @p99_duration = durations[(durations.size * 0.99).to_i] || 0
    else
      @avg_duration = @p95_duration = @p99_duration = 0
    end

    @pagy, @transactions = pagy(transactions, limit: 50)
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
    require 'csv'

    CSV.generate(headers: true) do |csv|
      # Headers
      csv << [
        'Transaction ID',
        'Timestamp',
        'Transaction Name',
        'Operation',
        'Duration (ms)',
        'DB Time (ms)',
        'View Time (ms)',
        'Environment',
        'Release',
        'Server Name',
        'HTTP Method',
        'HTTP Status',
        'HTTP URL',
        'Total Queries',
        'Unique Query Patterns',
        'N+1 Patterns',
        'DB Overhead %',
        'View Overhead %',
        'Other Time (ms)',
        'Controller',
        'Action',
        'Created At'
      ]

      # Data row
      csv << [
        @transaction.transaction_id,
        @transaction.timestamp,
        @transaction.transaction_name,
        @transaction.op,
        @transaction.duration,
        @transaction.db_time,
        @transaction.view_time,
        @transaction.environment,
        @transaction.release,
        @transaction.server_name,
        @transaction.http_method,
        @transaction.http_status,
        @transaction.http_url,
        @transaction.query_count,
        @transaction.unique_query_patterns,
        @transaction.potential_n_plus_one_queries.size,
        @transaction.db_overhead_percentage,
        @transaction.view_overhead_percentage,
        @transaction.other_time,
        @transaction.controller,
        @transaction.action,
        @transaction.created_at
      ]

      # Add query patterns as additional rows if present
      if @transaction.query_patterns.any?
        csv << [] # Empty row for separation
        csv << ['Query Patterns Details']
        csv << ['Pattern', 'Count', 'Example Query']

        @transaction.query_patterns.each do |pattern, data|
          csv << [
            pattern,
            data[:count],
            data[:examples]&.first&.truncate(200) || 'N/A'
          ]
        end
      end

      # Add N+1 warnings as additional rows if present
      if @transaction.has_n_plus_one_queries?
        csv << [] # Empty row for separation
        csv << ['N+1 Query Warnings']
        csv << ['Pattern']

        @transaction.potential_n_plus_one_queries.each do |pattern|
          csv << [pattern]
        end
      end

      # Add tags as additional rows if present
      if @transaction.tags.present? && @transaction.tags.any?
        csv << [] # Empty row for separation
        csv << ['Tags']
        csv << ['Key', 'Value']

        @transaction.tags.each do |key, value|
          csv << [key, value]
        end
      end
    end
  end
end
