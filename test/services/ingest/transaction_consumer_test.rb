require "test_helper"

class Ingest::TransactionConsumerTest < ActiveSupport::TestCase
  setup do
    @project = projects(:one)
    @consumer = Ingest::TransactionConsumer.new
  end

  # Stub beanstalkd job: process_batch reads .body and calls .delete on :ok.
  def job_for(transaction_id:, spans:)
    payload = {
      "transaction" => "ProductsController#show",
      "start_timestamp" => 1_700_000_000.0,
      "timestamp" => 1_700_000_000.5,
      "contexts" => {"trace" => {"op" => "http.server", "trace_id" => "trace-abc", "span_id" => "root"}},
      "spans" => spans
    }
    body = {"project_id" => @project.id, "transaction_id" => transaction_id, "payload" => payload}.to_json
    Struct.new(:body) { def delete = nil }.new(body)
  end

  def sample_spans(n = 3)
    (1..n).map do |i|
      {
        "span_id" => "s#{i}", "parent_span_id" => "root", "op" => "db.sql.active_record",
        "description" => "SELECT * FROM products WHERE id = #{i}",
        "start_timestamp" => 1_700_000_000.1, "timestamp" => 1_700_000_000.2
      }
    end
  end

  test "first delivery writes one span_tree blob and no legacy span rows" do
    job = job_for(transaction_id: "txn-1", spans: sample_spans(3))

    assert_difference -> { SpanTree.count }, 1 do
      assert_no_difference -> { Span.count } do
        @consumer.send(:process_batch, [job])
      end
    end

    tree = SpanTree.find_by(project_id: @project.id, transaction_id: "txn-1")
    assert_equal 4, tree.span_count, "root span + 3 children"
    refute tree.spans_truncated
    assert_equal "trace-abc", tree.tree["trace_id"]
  end

  test "redelivery of the same transaction does not write a second span_tree" do
    spans = sample_spans(2)
    @consumer.send(:process_batch, [job_for(transaction_id: "txn-dup", spans: spans)])

    assert_no_difference -> { SpanTree.count } do
      @consumer.send(:process_batch, [job_for(transaction_id: "txn-dup", spans: spans)])
    end
  end

  test "spans beyond the cap are truncated and flagged" do
    job = job_for(transaction_id: "txn-cap", spans: sample_spans(Transaction::SPAN_CAP + 5))
    @consumer.send(:process_batch, [job])

    tree = SpanTree.find_by(transaction_id: "txn-cap")
    assert_equal Transaction::SPAN_CAP + 1, tree.span_count, "root + capped children"
    assert tree.spans_truncated
  end

  test "round-trips through Span.for_transaction as Span::Node" do
    @consumer.send(:process_batch, [job_for(transaction_id: "txn-rt", spans: sample_spans(2))])

    nodes = Span.for_transaction("txn-rt", project_id: @project.id)
    assert nodes.all? { |n| n.is_a?(Span::Node) }
    assert_equal "http.server", nodes.first.op, "root span first"
    assert(nodes.any? { |n| n.op == "db.sql.active_record" })
    assert_equal "trace-abc", nodes.first.trace_id
  end

  test "build_span_tree hoists trace_id and uses ts/end_ts keys" do
    rows = @consumer.send(:build_span_rows,
      Transaction.new(project_id: @project.id, transaction_id: "x", timestamp: Time.current),
      {"contexts" => {"trace" => {"trace_id" => "tr", "span_id" => "root"}},
       "spans" => sample_spans(1)})
    tree = @consumer.send(:build_span_tree, rows)

    assert_equal "tr", tree["trace_id"]
    span = tree["spans"].first
    assert span.key?("ts"), "on-disk key is ts (decoded by Span::Node.from_tree)"
    assert span.key?("end_ts")
    refute span.key?("timestamp")
  end
end
