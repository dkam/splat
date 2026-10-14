require "test_helper"

class HealthControllerTest < ActionDispatch::IntegrationTest
  test "reports the recurring jobs as running while monitor_evaluation keeps running" do
    ScheduleRun.record!("monitor_evaluation", at: 1.minute.ago)

    get "/_health"

    body = response.parsed_body
    assert_equal "ok", body["status"]
    assert_equal "ok", body.dig("scheduler", "status")
  end

  # Monitor evaluation is what raises alerts, so a stopped schedule can't alert
  # through Splat. /_health is what Uptime Kuma polls.
  test "is degraded when nothing has run the schedule" do
    ScheduleRun.record!("monitor_evaluation", at: 10.minutes.ago)

    get "/_health"

    body = response.parsed_body
    assert_equal "degraded", body["status"]
    assert_equal "late", body.dig("scheduler", "status")
    assert_equal "monitor_evaluation", body.dig("scheduler", "entry")
  end

  test "reports the spool, and is degraded while it holds jobs" do
    ScheduleRun.record!("monitor_evaluation", at: 1.minute.ago)
    with_stub(Ingest::Tuber, :put, ->(*, **) { raise Errno::ECONNREFUSED }) do
      Ingest::Spool.put(Ingest::Tuber::EVENTS_TUBE, {"n" => 1})
    end

    get "/_health"

    body = response.parsed_body
    assert_equal "degraded", body["status"]
    assert_equal 1, body.dig("spool", "jobs")
    assert_operator body.dig("spool", "bytes"), :>, 0
  end
end
