# frozen_string_literal: true

# The performance dashboard's grouped surface — endpoints (= transaction_name)
# is to transactions what an Issue is to events. Three actions:
#
#   index       — the project's endpoints on one clock (PerformanceTimeline),
#                 web requests and background jobs apart, ranked by impact
#   show        — one endpoint's detail (percentiles, recent transactions)
#   n_plus_one  — endpoints with detected N+1 query patterns, ranked
#
# index and detail also take ?from=&to= (TimeWindowParam) in place of
# ?time_range=: a click on the project timeline's Throughput, Latency or
# endpoint row opens them for that bucket. ?sort=slowest lists the
# transactions slowest first, which is what the latency rows ask for.
#
# Single-transaction drill-down still lives at TransactionsController#show.
class EndpointsController < ApplicationController
  include Pagy::Method
  include TimeWindowParam

  before_action :set_project

  helper_method :range_params

  SORTS = %w[recent slowest].freeze

  def index
    @time_range = params[:time_range].presence_in(ProjectTimeline::WINDOWS.keys) || "24h"
    @window = time_window_param
    @sort = params[:sort].presence_in(SORTS) || "recent"
    @name_query = params[:name].to_s.strip.presence
    @environment = params[:environment].presence
    # Web requests, background jobs or other (TransactionKind); nil is all of
    # them, each drawn apart.
    @kind = TransactionKind.normalize(params[:kind])

    @timeline = PerformanceTimeline.new(@project, window: @time_range, range: @window, kind: @kind,
      environment: @environment, name_query: @name_query)

    # The feed covers the timeline's window, and the same names as its rows:
    # a row here is the kind its endpoint is drawn under.
    @kind_lookup = TransactionKind.lookup(@project.id)
    base_scope = @project.transactions.where(timestamp: @timeline.range)
    base_scope = base_scope.where(environment: @environment) if @environment
    base_scope = base_scope.where("transaction_name LIKE ?", "%#{@name_query}%") if @name_query
    kind_sql, kind_binds = @kind_lookup.clause(@kind)
    base_scope = base_scope.where(kind_sql, *kind_binds) if kind_sql

    # Countless: this feed is the whole project's transactions, which runs to
    # thousands of pages. A counted paginator would COUNT(*) the lot on every
    # load (and render a bogus "last page"); countless drops both.
    @pagy, @transactions = pagy(:countless, base_scope.order(transaction_order), limit: 50)

    @environments = cached_environments
  end

  def detail
    @endpoint = params[:name] || params[:endpoint]
    @time_range = params[:time_range] || "24h"
    @window = time_window_param
    @sort = params[:sort].presence_in(SORTS) || "recent"
    time_range = @window || (time_range_lower_bound(@time_range)..Time.current)

    stats = Transaction.percentiles_for_endpoint(@endpoint, time_range, project_id: @project.id)
    @p50_duration = stats["p50_duration"]&.to_f&.round
    @p95_duration = stats["p95_duration"]&.to_f&.round
    @p99_duration = stats["p99_duration"]&.to_f&.round

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
      .where(timestamp: time_range)
      .order(transaction_order)

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

  # What a link to another endpoints page carries: the window or the range,
  # and the order when it isn't the usual one.
  def range_params
    carried = @window ? {from: @window.begin.utc.iso8601, to: @window.end.utc.iso8601} : {time_range: @time_range}
    (@sort == "slowest") ? carried.merge(sort: @sort) : carried
  end

  def transaction_order
    (@sort == "slowest") ? {duration: :desc, id: :desc} : {timestamp: :desc}
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
