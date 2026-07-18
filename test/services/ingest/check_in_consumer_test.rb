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

  test "drops check-ins for a missing project without raising" do
    job = job_with("project_id" => -1, "payload" => {"monitor_slug" => "x", "status" => "ok"})
    assert_no_difference -> { CronMonitor.count } do
      @consumer.send(:process_batch, [job])
    end
  end
end
