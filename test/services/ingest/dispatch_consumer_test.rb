require "test_helper"

class Ingest::DispatchConsumerTest < ActiveSupport::TestCase
  setup do
    @consumer = Ingest::DispatchConsumer.new(tube: Ingest::Tuber::MAINTENANCE_TUBE)
    @performed = performed = []
    Object.const_set(:DispatchConsumerTestJob, Class.new { define_method(:perform) { |*args| performed << args } })
  end

  teardown { Object.send(:remove_const, :DispatchConsumerTestJob) }

  def job_with(body)
    Struct.new(:body, :deleted) { def delete = self.deleted = true }.new(body.to_json)
  end

  test "records the run of a scheduled entry before running it" do
    job = job_with("class" => "DispatchConsumerTestJob", "args" => ["deep"], "schedule" => "storage_stats_deep")

    freeze_time do
      @consumer.send(:process_batch, [job])
      assert_equal Time.current, ScheduleRun.find_by!(name: "storage_stats_deep").last_run_at
    end
    assert_equal [["deep"]], @performed
    assert job.deleted
  end

  test "a body without a schedule name is run but not recorded" do
    # What a job queued by hand looks like (see "Running it now" in the README).
    @consumer.send(:process_batch, [job_with("class" => "DispatchConsumerTestJob", "args" => [])])

    assert_equal [[]], @performed
    assert_equal 0, ScheduleRun.count
  end

  test "a run that can't be recorded still runs" do
    with_stub(ScheduleRun, :upsert, ->(*, **) { raise ActiveRecord::StatementInvalid, "database is locked" }) do
      @consumer.send(:process_batch, [job_with("class" => "DispatchConsumerTestJob", "args" => [], "schedule" => "data_retention")])
    end

    assert_equal [[]], @performed
  end
end
