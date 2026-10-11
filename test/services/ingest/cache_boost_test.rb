# frozen_string_literal: true

require "test_helper"

class Ingest::CacheBoostTest < ActiveSupport::TestCase
  NORMAL_KB = 2_000
  BOOST_KB = 20_000

  setup do
    @now = 0.0
    @reports = []
    @conn = TransactionsSpansRecord.connection_pool.lease_connection
    @boost = Ingest::CacheBoost.new(
      name: "Ingest::TransactionConsumer", connection: @conn,
      normal_kb: NORMAL_KB, boost_kb: BOOST_KB,
      reporter: ->(summary) { @reports << summary },
      clock: -> { @now }
    )
  end

  # The pragma outlives the test on a reused connection; put it back.
  teardown { @conn.execute("PRAGMA cache_size = -#{NORMAL_KB}") }

  def cache_kb = -@conn.select_value("PRAGMA cache_size").to_i

  test "a full reserve raises the cache on the write connection" do
    @boost.reserved(Ingest::CacheBoost::BOOST_BATCH)

    assert_equal BOOST_KB, cache_kb
  end

  test "a reserve short of a backlog leaves the cache small" do
    @conn.execute("PRAGMA cache_size = -#{NORMAL_KB}")
    @boost.reserved(Ingest::CacheBoost::BOOST_BATCH - 1)

    assert_equal NORMAL_KB, cache_kb
  end

  test "stays raised through the hold after the last full reserve, then drops back" do
    @boost.reserved(50)

    @now = Ingest::CacheBoost::HOLD_SECONDS - 1
    @boost.reserved(1)
    assert_equal BOOST_KB, cache_kb, "a lull shorter than the hold keeps the cache"

    @now = Ingest::CacheBoost::HOLD_SECONDS + 1
    @boost.reserved(0)
    assert_equal NORMAL_KB, cache_kb, "the cache shrinks once the hold has passed"
  end

  test "another full reserve extends the hold" do
    @boost.reserved(50)
    @now = 50
    @boost.reserved(50)
    @now = 100
    @boost.reserved(1)

    assert_equal BOOST_KB, cache_kb
  end

  test "reports jobs and time per cache size once a window" do
    3.times do
      @boost.reserved(1)
      @boost.processed(1, 10)
    end
    @boost.reserved(25)
    @boost.processed(25, 200)

    @now = Ingest::CacheBoost::REPORT_SECONDS + 1
    @boost.report_if_due
    @boost.report_if_due

    assert_equal 1, @reports.size, "one report per window"
    r = @reports.first
    assert_equal "Ingest::TransactionConsumer", r[:consumer]
    assert_equal 28, r[:jobs]
    assert_equal 4, r[:batches]
    assert_equal 25, r[:max_batch]
    assert_equal 3, r[:normal_jobs]
    assert_in_delta 10.0, r[:normal_ms_per_job]
    assert_equal 25, r[:boosted_jobs]
    assert_in_delta 8.0, r[:boosted_ms_per_job]
    assert_equal 1, r[:boosts]
    assert_equal BOOST_KB, r[:cache_kb]
  end

  test "counts the time spent boosted within the window" do
    @now = 10
    @boost.reserved(50)
    @now = 10 + Ingest::CacheBoost::HOLD_SECONDS + 5
    @boost.reserved(0) # drops back at t=75: boosted for 65s

    @now = 130
    @boost.report_if_due

    assert_in_delta 65.0, @reports.first[:boosted_s], 0.01
  end

  test "the next window starts from zero" do
    @boost.reserved(1)
    @boost.processed(1, 10)
    @now = Ingest::CacheBoost::REPORT_SECONDS + 1
    @boost.report_if_due

    @boost.reserved(1)
    @boost.processed(1, 30)
    @now = 2 * Ingest::CacheBoost::REPORT_SECONDS + 2
    @boost.report_if_due

    assert_equal 2, @reports.size
    assert_equal 1, @reports.last[:jobs]
    assert_in_delta 30.0, @reports.last[:normal_ms_per_job]
  end

  test "says nothing for a window with no work" do
    @boost.reserved(0)
    @now = 10 * Ingest::CacheBoost::REPORT_SECONDS
    @boost.report_if_due

    assert_empty @reports
  end

  # Splat's own Splat is where the numbers get judged, so the default reporter
  # has to reach Sentry's structured log with them as attributes.
  test "the default report goes to Sentry's structured log" do
    sent = []
    fake_logger = Object.new
    fake_logger.define_singleton_method(:info) { |message, params = [], **attrs| sent << [message, params, attrs] }
    boost = Ingest::CacheBoost.new(name: "Ingest::LogConsumer", connection: @conn,
      normal_kb: NORMAL_KB, boost_kb: BOOST_KB, clock: -> { @now })
    boost.reserved(1)
    boost.processed(1, 12)
    @now = Ingest::CacheBoost::REPORT_SECONDS + 1

    with_stub(Sentry, :initialized?, -> { true }) do
      with_stub(Sentry, :logger, -> { fake_logger }) { boost.report_if_due }
    end

    assert_equal 1, sent.size
    message, params, attrs = sent.first
    assert_equal "Ingest::LogConsumer", params.first
    assert_equal message.scan("%s").size, params.size, "every placeholder gets a parameter"
    assert_equal 1, attrs[:jobs]
    assert_in_delta 12.0, attrs[:normal_ms_per_job]
    assert_equal NORMAL_KB, attrs[:cache_kb]
  end

  test "a failing reporter never reaches the consumer loop" do
    boost = Ingest::CacheBoost.new(
      name: "x", connection: @conn, normal_kb: NORMAL_KB, boost_kb: BOOST_KB,
      reporter: ->(_) { raise "splat-splat is down" }, clock: -> { @now }
    )
    boost.reserved(1)
    boost.processed(1, 10)
    @now = Ingest::CacheBoost::REPORT_SECONDS + 1

    assert_nothing_raised { boost.report_if_due }
  end
end
