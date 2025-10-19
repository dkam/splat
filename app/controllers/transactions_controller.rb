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
    # Transaction detail page
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
end
