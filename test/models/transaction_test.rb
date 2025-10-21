require "test_helper"

class TransactionTest < ActiveSupport::TestCase
  def setup
    @project = Project.create!(name: "Test Project", slug: "test", public_key: "test-key")
  end

  test "create_from_sentry_payload! creates transaction with basic data" do
    payload = {
      "transaction" => "GET /api/users",
      "start_timestamp" => "2025-10-18T08:00:00.000Z",
      "timestamp" => "2025-10-18T08:00:00.250Z",
      "contexts" => {
        "trace" => {
          "op" => "http.server"
        }
      }
    }

    transaction = Transaction.create_from_sentry_payload!("txn-id-1", payload, @project)

    assert_equal "txn-id-1", transaction.transaction_id
    assert_equal @project, transaction.project
    assert_equal "GET /api/users", transaction.transaction_name
    assert_equal "http.server", transaction.op
    assert_equal 250, transaction.duration # 250ms
  end

  test "create_from_sentry_payload! includes HTTP context" do
    payload = {
      "transaction" => "UsersController#show",
      "start_timestamp" => 1729238400.0,
      "timestamp" => 1729238400.5,
      "request" => {
        "method" => "GET",
        "url" => "https://example.com/users/123"
      },
      "contexts" => {
        "response" => {
          "status_code" => 200
        },
        "trace" => {
          "op" => "http.server"
        }
      }
    }

    transaction = Transaction.create_from_sentry_payload!("txn-http", payload, @project)

    assert_equal "GET", transaction.http_method
    assert_equal "200", transaction.http_status
    assert_equal "https://example.com/users/123", transaction.http_url
  end

  test "create_from_sentry_payload! includes measurements" do
    payload = {
      "transaction" => "ProductsController#index",
      "start_timestamp" => "2025-10-18T08:00:00.000Z",
      "timestamp" => "2025-10-18T08:00:01.500Z",
      "measurements" => {
        "db" => { "value" => 800 },
        "view" => { "value" => 200 },
        "custom_metric" => { "value" => 42 }
      }
    }

    transaction = Transaction.create_from_sentry_payload!("txn-measurements", payload, @project)

    assert_equal 1500, transaction.duration
    assert_equal 800, transaction.db_time
    assert_equal 200, transaction.view_time
    expected_measurements = {
      "db" => { "value" => 800 },
      "view" => { "value" => 200 },
      "custom_metric" => { "value" => 42 },
      "span_extracted_db_time" => 800,
      "span_extracted_view_time" => 200
    }
    assert_equal(expected_measurements, transaction.measurements)
  end

  test "create_from_sentry_payload! includes environment and release" do
    payload = {
      "transaction" => "ApiController#endpoint",
      "start_timestamp" => "2025-10-18T08:00:00.000Z",
      "timestamp" => "2025-10-18T08:00:00.100Z",
      "environment" => "production",
      "release" => "v2.3.4",
      "server_name" => "web-2"
    }

    transaction = Transaction.create_from_sentry_payload!("txn-env", payload, @project)

    assert_equal "production", transaction.environment
    assert_equal "v2.3.4", transaction.release
    assert_equal "web-2", transaction.server_name
  end

  test "create_from_sentry_payload! includes tags" do
    payload = {
      "transaction" => "WorkerJob#perform",
      "start_timestamp" => "2025-10-18T08:00:00.000Z",
      "timestamp" => "2025-10-18T08:00:00.500Z",
      "tags" => {
        "locale" => "en",
        "region" => "us-west-2",
        "feature_flag" => "new_ui"
      }
    }

    transaction = Transaction.create_from_sentry_payload!("txn-tags", payload, @project)

    assert_equal({ "locale" => "en", "region" => "us-west-2", "feature_flag" => "new_ui" }, transaction.tags)
    assert_equal "en", transaction.tag("locale")
    assert_equal "us-west-2", transaction.tag("region")
  end

  test "slow? returns true for transactions over 1 second" do
    slow_txn = @project.transactions.create!(
      transaction_id: "slow-1",
      transaction_name: "SlowController#index",
      timestamp: Time.current,
      duration: 2500
    )

    fast_txn = @project.transactions.create!(
      transaction_id: "fast-1",
      transaction_name: "FastController#index",
      timestamp: Time.current,
      duration: 200
    )

    assert slow_txn.slow?
    assert_not fast_txn.slow?
  end

  test "http_success? and http_error? detect status codes" do
    success = @project.transactions.create!(
      transaction_id: "success-1",
      transaction_name: "Test",
      timestamp: Time.current,
      duration: 100,
      http_status: "200"
    )

    error = @project.transactions.create!(
      transaction_id: "error-1",
      transaction_name: "Test",
      timestamp: Time.current,
      duration: 100,
      http_status: "500"
    )

    client_error = @project.transactions.create!(
      transaction_id: "error-2",
      transaction_name: "Test",
      timestamp: Time.current,
      duration: 100,
      http_status: "404"
    )

    assert success.http_success?
    assert_not success.http_error?

    assert error.http_error?
    assert_not error.http_success?

    assert client_error.http_error?
    assert_not client_error.http_success?
  end

  test "db_overhead_percentage calculates correctly" do
    txn = @project.transactions.create!(
      transaction_id: "overhead-1",
      transaction_name: "Test",
      timestamp: Time.current,
      duration: 1000,
      db_time: 600
    )

    assert_equal 60.0, txn.db_overhead_percentage
  end

  test "view_overhead_percentage calculates correctly" do
    txn = @project.transactions.create!(
      transaction_id: "overhead-2",
      transaction_name: "Test",
      timestamp: Time.current,
      duration: 1000,
      view_time: 250
    )

    assert_equal 25.0, txn.view_overhead_percentage
  end

  test "other_time calculates remaining time correctly" do
    txn = @project.transactions.create!(
      transaction_id: "other-1",
      transaction_name: "Test",
      timestamp: Time.current,
      duration: 1000,
      db_time: 600,
      view_time: 200
    )

    assert_equal 200, txn.other_time # 1000 - 600 - 200
  end

  test "controller_action, controller, and action parse transaction name" do
    rails_txn = @project.transactions.create!(
      transaction_id: "rails-1",
      transaction_name: "UsersController#show",
      timestamp: Time.current,
      duration: 100
    )

    non_rails_txn = @project.transactions.create!(
      transaction_id: "other-1",
      transaction_name: "GET /api/users",
      timestamp: Time.current,
      duration: 100
    )

    assert_equal "UsersController#show", rails_txn.controller_action
    assert_equal "UsersController", rails_txn.controller
    assert_equal "show", rails_txn.action

    assert_nil non_rails_txn.controller_action
    assert_nil non_rails_txn.controller
    assert_nil non_rails_txn.action
  end

  test "measurement returns specific measurement value" do
    txn = @project.transactions.create!(
      transaction_id: "measure-1",
      transaction_name: "Test",
      timestamp: Time.current,
      duration: 100,
      measurements: {
        "custom_timer" => { "value" => 42.5 },
        "memory_used" => { "value" => 1024 }
      }
    )

    assert_equal 42.5, txn.measurement("custom_timer")
    assert_equal 1024, txn.measurement("memory_used")
    assert_nil txn.measurement("nonexistent")
  end

  test "stats_by_endpoint aggregates transaction statistics" do
    3.times do |i|
      @project.transactions.create!(
        transaction_id: "stats-slow-#{i}",
        transaction_name: "SlowEndpoint",
        timestamp: Time.current,
        duration: 500 + (i * 100),
        db_time: 200 + (i * 50),
        view_time: 100 + (i * 25)
      )
    end

    2.times do |i|
      @project.transactions.create!(
        transaction_id: "stats-fast-#{i}",
        transaction_name: "FastEndpoint",
        timestamp: Time.current,
        duration: 100 + (i * 10),
        db_time: 50 + (i * 5)
      )
    end

    stats = Transaction.stats_by_endpoint.to_a

    assert_equal 2, stats.length

    slow_stats = stats.find { |s| s.transaction_name == "SlowEndpoint" }
    fast_stats = stats.find { |s| s.transaction_name == "FastEndpoint" }

    assert_equal 600, slow_stats.avg_duration.to_i
    assert_equal 3, slow_stats.count

    assert_equal 105, fast_stats.avg_duration.to_i
    assert_equal 2, fast_stats.count
  end

  test "percentiles calculates distribution correctly" do
    # Create transactions with durations: 100, 200, 300, 400, 500
    5.times do |i|
      @project.transactions.create!(
        transaction_id: "perc-#{i}",
        transaction_name: "Test",
        timestamp: Time.current,
        duration: (i + 1) * 100
      )
    end

    percentiles = Transaction.percentiles

    assert_equal 300, percentiles[:avg]
    assert_equal 300, percentiles[:p50]
    assert_equal 100, percentiles[:min]
    assert_equal 500, percentiles[:max]
    assert percentiles[:p95] >= 400
    assert percentiles[:p99] >= 400
  end

  test "time-based scopes filter correctly" do
    old_transaction = @project.transactions.create!(
      transaction_id: "old-1",
      transaction_name: "Test",
      timestamp: 2.days.ago,
      duration: 100
    )

    recent_transaction = @project.transactions.create!(
      transaction_id: "recent-1",
      transaction_name: "Test",
      timestamp: 30.minutes.ago,
      duration: 100
    )

    assert_includes Transaction.last_hour, recent_transaction
    assert_not_includes Transaction.last_hour, old_transaction

    assert_includes Transaction.last_24_hours, recent_transaction
    assert_not_includes Transaction.last_24_hours, old_transaction

    assert_includes Transaction.last_7_days, recent_transaction
    assert_includes Transaction.last_7_days, old_transaction
  end

  test "scopes filter by attributes correctly" do
    get_transaction = @project.transactions.create!(
      transaction_id: "get-1",
      transaction_name: "UsersController#index",
      timestamp: Time.current,
      duration: 100,
      http_method: "GET",
      http_status: "200",
      environment: "production",
      server_name: "web-1"
    )

    post_transaction = @project.transactions.create!(
      transaction_id: "post-1",
      transaction_name: "UsersController#create",
      timestamp: Time.current,
      duration: 200,
      http_method: "POST",
      http_status: "201",
      environment: "staging"
    )

    assert_includes Transaction.by_name("UsersController#index"), get_transaction
    assert_not_includes Transaction.by_name("UsersController#index"), post_transaction

    assert_includes Transaction.by_http_method("GET"), get_transaction
    assert_not_includes Transaction.by_http_method("GET"), post_transaction

    assert_includes Transaction.by_http_status("200"), get_transaction
    assert_not_includes Transaction.by_http_status("200"), post_transaction

    assert_includes Transaction.by_environment("production"), get_transaction
    assert_not_includes Transaction.by_environment("production"), post_transaction

    assert_includes Transaction.by_server("web-1"), get_transaction
    assert_not_includes Transaction.by_server("web-1"), post_transaction
  end

  test "slow scope returns only slow transactions" do
    slow_txn = @project.transactions.create!(
      transaction_id: "slow-scope",
      transaction_name: "Slow",
      timestamp: Time.current,
      duration: 1500
    )

    fast_txn = @project.transactions.create!(
      transaction_id: "fast-scope",
      transaction_name: "Fast",
      timestamp: Time.current,
      duration: 500
    )

    slow_transactions = Transaction.slow

    assert_includes slow_transactions, slow_txn
    assert_not_includes slow_transactions, fast_txn
  end
end
