require "test_helper"

class Ingest::CheckInConsumerTest < ActiveSupport::TestCase
  setup do
    @project = projects(:one)
    @consumer = Ingest::CheckInConsumer.new
  end

  # Stub beanstalkd job: process_batch reads .body and calls .delete on :ok.
  def job_with(body)
    Struct.new(:body) { def delete = nil }.new(body.to_json)
  end

  test "records a check-in body as a Monitor upsert" do
    job = job_with(
      "project_id" => @project.id,
      "payload" => {
        "monitor_slug" => "meili-flush",
        "status" => "ok",
        "monitor_config" => {"schedule" => {"type" => "interval", "value" => 1, "unit" => "minute"}}
      }
    )

    assert_difference -> { CronMonitor.count }, 1 do
      @consumer.send(:process_batch, [job])
    end
    assert_equal "ok", CronMonitor.find_by!(project: @project, slug: "meili-flush").last_status
  end

  test "dispatches scheduler bodies by class name" do
    performed = []
    klass = Class.new do
      define_method(:perform) { |*args| performed << args }
    end
    Object.const_set(:CheckInConsumerTestJob, klass)

    @consumer.send(:process_batch, [job_with("class" => "CheckInConsumerTestJob", "args" => [1])])
    assert_equal [[1]], performed
  ensure
    Object.send(:remove_const, :CheckInConsumerTestJob)
  end

  test "records a run of a scheduled entry, whoever put it" do
    Object.const_set(:CheckInConsumerTestJob, Class.new { def perform(*) = nil })

    freeze_time do
      @consumer.send(:process_batch, [job_with("class" => "CheckInConsumerTestJob", "args" => [], "schedule" => "monitor_evaluation")])
      assert_equal Time.current, ScheduleRun.find_by!(name: "monitor_evaluation").last_run_at
    end
  ensure
    Object.send(:remove_const, :CheckInConsumerTestJob)
  end

  test "drops check-ins for a missing project without raising" do
    job = job_with("project_id" => -1, "payload" => {"monitor_slug" => "x", "status" => "ok"})
    assert_no_difference -> { CronMonitor.count } do
      @consumer.send(:process_batch, [job])
    end
  end

  # --- Putting a lost schedule back -------------------------------------------

  # A tuber restarted without a binlog comes back with no schedule, and with
  # no bin/scheduler running nothing would put it back. Every consumer
  # reconnects after a restart; this one runs monitor_evaluation, so it's the
  # one that checks.
  def connect_with(restore)
    client = Object.new
    tubes = Object.new
    watched = []
    tubes.define_singleton_method(:watch!) { |tube| watched << tube }
    client.define_singleton_method(:tubes) { tubes }
    restores = 0
    ok = with_stub(Ingest::Tuber, :consumer_client, -> { client }) do
      with_stub(Ingest::Schedule, :restore_if_lost, -> { restores += 1 and restore.call }) do
        @consumer.send(:connect_with_retry)
      end
    end
    [ok, watched, restores]
  end

  test "on connecting, it puts back a schedule tuber has lost" do
    ok, watched, restores = connect_with(-> { Tuber::Schedules::SyncResult.new(9, 0, 0, 0) })

    assert ok
    assert_equal [Ingest::Tuber::CHECKINS_TUBE], watched
    assert_equal 1, restores
  end

  test "a tuber too old for schedules, or one refusing them, never stops it consuming" do
    [Ingest::Schedule::Unsupported.new("old"), Tuber::ScheduleSyncError.new("BAD_SCHEDULE", "x", owner: "splat")].each do |error|
      ok, watched, _restores = connect_with(-> { raise error })

      assert ok, error.class.name
      assert_equal [Ingest::Tuber::CHECKINS_TUBE], watched
    end
  end
end
