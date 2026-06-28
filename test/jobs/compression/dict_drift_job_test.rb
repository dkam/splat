require "test_helper"

class Compression::DictDriftJobTest < ActiveSupport::TestCase
  test "fans out training jobs for both events and logs segments" do
    Compression::IssuesEventsDict.create!(segment: "events", version: 1, dict: "x", trained_at: Time.current, active: true)
    Compression::LogsDict.create!(segment: "logs", version: 1, dict: "y", trained_at: Time.current, active: true)
    Compression::LogsDict.create!(segment: "logs:platform:sentry", version: 1, dict: "z", trained_at: Time.current, active: true)

    fanned = []
    with_stub(Ingest::Tuber, :put, ->(tube, body, **) { fanned << body["args"].first }) do
      Compression::DictDriftJob.new.perform
    end

    assert_includes fanned, "events"
    assert_includes fanned, "logs"
    assert_includes fanned, "logs:platform:sentry"
  end

  test "training job registry resolves the logs segment to the logs db" do
    # segment_qualifier maps the "platform" qualifier onto the table's column —
    # source for logs, platform for events.
    job = Compression::DictTrainingJob.new
    events_q = job.send(:segment_qualifier, "events", "events:platform:python")
    logs_q = job.send(:segment_qualifier, "logs", "logs:platform:sentry")

    assert_equal ["AND platform = ?", "python"], events_q
    assert_equal ["AND source = ?", "sentry"], logs_q
  end
end
