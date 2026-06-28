# frozen_string_literal: true

require "test_helper"

class Ingest::WorkerTest < ActiveSupport::TestCase
  test "ingest role runs the real-time data tube consumers, not maintenance" do
    classes = Ingest::Worker.consumers_for("ingest").map(&:class)

    assert_includes classes, Ingest::EventConsumer
    assert_includes classes, Ingest::TransactionConsumer
    assert_includes classes, Ingest::LogConsumer
    assert_includes classes, Ingest::ForwardConsumer
    assert_includes classes, Ingest::ActiveJobConsumer
    refute_includes classes, Ingest::DispatchConsumer
  end

  test "maintenance role runs only the maintenance dispatcher" do
    consumers = Ingest::Worker.consumers_for("maintenance")

    assert_equal [Ingest::DispatchConsumer], consumers.map(&:class)
    assert_equal Ingest::Tuber::MAINTENANCE_TUBE, consumers.first.tube
  end

  test "the two roles together cover every consumer the single worker ran" do
    all = (Ingest::Worker.consumers_for("ingest") +
           Ingest::Worker.consumers_for("maintenance")).map(&:class).sort_by(&:name)

    expected = [
      Ingest::EventConsumer, Ingest::TransactionConsumer, Ingest::LogConsumer,
      Ingest::ForwardConsumer, Ingest::ActiveJobConsumer, Ingest::DispatchConsumer
    ].sort_by(&:name)

    assert_equal expected, all
  end

  test "an unknown role raises a helpful error" do
    err = assert_raises(ArgumentError) { Ingest::Worker.consumers_for("nope") }
    assert_match(/unknown worker role/, err.message)
  end
end
