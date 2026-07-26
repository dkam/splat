# frozen_string_literal: true

# The performance dashboard's grouped surface — endpoints (= transaction_name)
# is to transactions what an Issue is to events. Three actions:
#
#   index       — all endpoints in the project, ranked by impact (avg × count)
#   show        — one endpoint's detail (percentiles, recent transactions)
#   n_plus_one  — endpoints with detected N+1 query patterns, ranked
#
# Single-transaction drill-down still lives at TransactionsController#show.
class EndpointsController < ApplicationController
  include Pagy::Method

  before_action :set_project

  def index
    @time_range = params[:time_range] || "24h"
    time_ago = time_range_lower_bound(@time_range)
    time_range = time_ago..Time.current
    @name_query = params[:name].to_s.strip.presence

    base_scope = @project.transactions.where("timestamp > ?", time_ago)
    base_scope = base_scope.where(environment: params[:environment]) if params[:environment].present?
    base_scope = base_scope.where("transaction_name LIKE ?", "%#{@name_query}%") if @name_query

    pct = Transaction.percentiles(time_range, project_id: @project.id, environment: params[:environment], name_query: @name_query)
    @p50_duration = pct[:p50] || 0
    @p95_duration = pct[:p95] || 0
    @p99_duration = pct[:p99] || 0

    # When the user has filtered by name we want to see every match, not just
    # the top 20 by impact.
    @endpoints = Transaction.stats_by_endpoint_with_impact(
      time_range,
      project_id: @project.id,
      environment: params[:environment],
      name_query: @name_query,
      limit: @name_query ? nil : 20
    )

    @sparkline_range = time_range
    sparkline_names = @endpoints.map { |e| e["transaction_name"] }
    sparkline_key = [
      "endpoints_p95_sparklines/v1", @project.id, @time_range,
      params[:environment].presence, @name_query, Digest::MD5.hexdigest(sparkline_names.join("\n"))
    ].join("/")
    @endpoint_sparklines = Rails.cache.fetch(sparkline_key, expires_in: 30.seconds) do
      Transaction.p95_by_bucket(
        transaction_names: sparkline_names,
        time_range: time_range,
        buckets: 24,
        project_id: @project.id,
        environment: params[:environment]
      )
    end

    # Countless: this feed is the whole project's transactions, which runs to
    # thousands of pages. A counted paginator would COUNT(*) the lot on every
    # load (and render a bogus "last page"); countless drops both.
    @pagy, @transactions = pagy(:countless, base_scope.order(timestamp: :desc), limit: 50)

    @environments = cached_environments
  end

  def detail
    @endpoint = params[:name] || params[:endpoint]
    @time_range = params[:time_range] || "24h"
    time_ago = time_range_lower_bound(@time_range)
    time_range = time_ago..Time.current

    stats = Transaction.percentiles_for_endpoint(@endpoint, time_range, project_id: @project.id)
    @p50_duration = stats["p50_duration"]&.to_f&.round || 0
    @p95_duration = stats["p95_duration"]&.to_f&.round || 0
    @p99_duration = stats["p99_duration"]&.to_f&.round || 0

    # The P95 trend always spans a full 7 days for long-range context, regardless
    # of the filter window above. Hourly buckets (168 over 7d) read directly from
    # the pre-aggregated histograms, so this stays cheap.
    @p95_sparkline_days = 7
    @p95_sparkline_range = @p95_sparkline_days.days.ago..Time.current
    @p95_sparkline = Transaction.p95_by_bucket(
      transaction_names: [@endpoint],
      time_range: @p95_sparkline_range,
      buckets: 168,
      project_id: @project.id
    )[@endpoint] || []

    transactions = @project.transactions
      .where(transaction_name: @endpoint)
      .where("timestamp > ?", time_ago)
      .order(timestamp: :desc)

    # Countless pagination: this endpoint can have ~80k transactions/day, so a
    # counted paginator would run a COUNT(*) over the whole window on every page
    # load. Countless drops the count and the jump-to-page links (next/prev only).
    @pagy, @transactions = pagy(:countless, transactions, limit: 50)
  end

  def n_plus_one
    @time_range = params[:time_range] || "24h"
    time_ago = time_range_lower_bound(@time_range)
    time_range = time_ago..Time.current

    @endpoints = Transaction.endpoints_by_n_plus_one(
      time_range, project_id: @project.id, environment: params[:environment], limit: 50
    )

    @environments = cached_environments
  end

  private

  def set_project
    @project = Project.find_by!(slug: params[:project_slug])
  end

  def time_range_lower_bound(range)
    case range
    when "1h" then 1.hour.ago
    when "6h" then 6.hours.ago
    when "24h" then 24.hours.ago
    when "7d" then 7.days.ago
    when "30d" then 30.days.ago
    else 24.hours.ago
    end
  end

  # Environment filter values, maintained at ingest in the facets table (primary
  # DB) — a covered lookup instead of a DISTINCT scan over the transactions table.
  def cached_environments
    Facet.values_for(@project.id, :transaction, :environment)
  end
end
