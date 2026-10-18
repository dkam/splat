require "test_helper"

# An SDK keeps a sampled share of its transactions and says which share in the
# envelope header (trace.sample_rate). Time spent per endpoint is only
# comparable once each row is scaled back up by it: Booko sends web requests at
# 1% and jobs at 10%, so as recorded a job looks ten times bigger beside a
# request than it is.
class SampleRateTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Sampled", slug: "sampled", public_key: "sampled-key")
    @hour = (Time.current - 2.hours).beginning_of_hour
    @range = (Time.current - 24.hours)..Time.current
  end

  test "time spent ranks endpoints by their real share, scaled by each transaction's sample rate" do
    # 1% of requests at 100ms: 1s as recorded, ~100s really.
    10.times { |i| ingest("ProductsController#show", 100, at: @hour + i.minutes, sample_rate: "0.01") }
    # 10% of jobs at 500ms: 5s as recorded, ~50s really.
    10.times { |i| ingest("CoverVariantsJob", 500, at: @hour + i.minutes, sample_rate: "0.1") }

    assert_ranked_by_real_time

    # The hourly rollup recounts the hour from the raw rows, and must scale
    # them the same way the live bump did.
    Analytics::HistogramRollupJob.new.perform(@hour)
    assert_ranked_by_real_time
  end

  test "the performance page and the MCP stats rank by the scaled figure, and keep the recorded one" do
    10.times { |i| ingest("ProductsController#show", 100, at: @hour + i.minutes, sample_rate: "0.01") }
    10.times { |i| ingest("CoverVariantsJob", 500, at: @hour + i.minutes, sample_rate: "0.1") }

    result = SplatMcpTools.new.get_transaction_stats("project" => @project.slug)
    rows = result.structured_content[:top_endpoints]
    assert_equal ["ProductsController#show", "CoverVariantsJob"], rows.map { it[:transaction_name] }
    assert_equal [100_000.0, 1_000.0], rows.first.values_at(:est_time_spent, :time_spent)
    assert_match(/\| ProductsController#show \| 100000ms \| 1000ms \|/, result.content.first[:text])

    get project_endpoints_url(@project.slug)
    assert_response :success
    assert_select "span[title^='Scaled up by the sample rate']", text: "1m 40s"
  end

  test "a transaction sent without a sample rate counts as itself" do
    3.times { |i| ingest("GET /unsampled", 200, at: @hour + i.minutes, sample_rate: nil) }

    row = Transaction.stats_by_endpoint_with_impact(@range, project_id: @project.id).sole
    assert_nil Transaction.find_by!(transaction_name: "GET /unsampled").sample_rate
    assert_equal 600, row["time_spent"]
    assert_equal 600, row["est_time_spent"]
    assert_equal 0, row["rated_count"]
  end

  private

  def assert_ranked_by_real_time
    ranked = Transaction.stats_by_endpoint_with_impact(@range, project_id: @project.id)
    assert_equal ["ProductsController#show", "CoverVariantsJob"], ranked.map { it["transaction_name"] }

    web, job = ranked
    assert_equal [1_000, 5_000], [web["time_spent"], job["time_spent"]], "as recorded"
    assert_in_delta 100_000, web["est_time_spent"], 1
    assert_in_delta 50_000, job["est_time_spent"], 1
    assert_in_delta 1_000, web["est_count"], 0.01
    assert_equal [10, 10], [web["rated_count"], job["rated_count"]]
  end

  # One transaction, posted as an SDK posts it and drained by the consumer.
  def ingest(name, duration_ms, at:, sample_rate:)
    trace_id = SecureRandom.hex(16)
    header = {event_id: SecureRandom.hex(16), sent_at: Time.current.iso8601}
    header[:trace] = {trace_id: trace_id, sample_rate: sample_rate, sampled: "true"} if sample_rate
    payload = {
      type: "transaction", transaction: name, platform: "ruby",
      start_timestamp: at.to_f, timestamp: (at + duration_ms / 1000.0).to_f,
      contexts: {trace: {trace_id: trace_id, span_id: SecureRandom.hex(8), op: "http.server"}}
    }
    body = [header.to_json, {type: "transaction"}.to_json, payload.to_json].join("\n")

    jobs = []
    queue = ->(tube, job, **) { jobs << JSON.generate(job) if tube == Ingest::Tuber::TRANSACTIONS_TUBE }
    with_stub(Ingest::Tuber, :put, queue) do
      post "/api/#{@project.slug}/envelope/?sentry_key=#{@project.public_key}",
        params: body, headers: {"Content-Type" => "application/x-sentry-envelope"}
      assert_response :success
    end

    job = Struct.new(:body, :outcome) do
      def delete = self.outcome = :done
      def release(**) = self.outcome = :retried
      def stats = Struct.new(:releases).new(0)
    end
    queued = jobs.map { job.new(it) }
    Ingest::TransactionConsumer.new.send(:process_batch, queued)
    assert_equal [:done], queued.map(&:outcome)
  end
end
