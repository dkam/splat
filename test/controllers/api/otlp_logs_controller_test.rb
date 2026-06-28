# frozen_string_literal: true

require "test_helper"

class Api::OtlpLogsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "OTLP Project", slug: "otlp-project", public_key: "otlp-key-123")
    @payload = {
      "resourceLogs" => [
        {"resource" => {"attributes" => []},
         "scopeLogs" => [{"logRecords" => [{"severityNumber" => 9, "body" => {"stringValue" => "hi"}}]}]}
      ]
    }
  end

  def with_tuber_stub
    calls = []
    with_stub(Ingest::Tuber, :put, ->(*args, **kw) { calls << [args, kw] }) { yield calls }
  end

  test "queues OTLP logs with a valid public key" do
    Setting.instance.update!(store_logs: true) # logs default off; opt in for this test
    with_tuber_stub do |calls|
      post "/v1/logs", params: @payload.to_json,
        headers: {"Content-Type" => "application/json", "Authorization" => "Bearer #{@project.public_key}"}
      assert_response :success

      logs_puts = calls.select { |args, _| args.first == Ingest::Tuber::LOGS_TUBE }
      assert_equal 1, logs_puts.size
      assert_equal "otlp", logs_puts.first[0][1][:format]
      assert_equal @project.id, logs_puts.first[0][1][:project_id]
    end
  end

  test "rejects an unknown public key" do
    with_tuber_stub do |calls|
      post "/v1/logs", params: @payload.to_json,
        headers: {"Content-Type" => "application/json", "Authorization" => "Bearer nope"}
      assert_response :unauthorized
      assert_empty calls
    end
  end

  test "rejects protobuf content type" do
    with_tuber_stub do |calls|
      post "/v1/logs", params: "binary",
        headers: {"Content-Type" => "application/x-protobuf", "Authorization" => "Bearer #{@project.public_key}"}
      assert_response :unsupported_media_type
      assert_empty calls
    end
  end

  test "accepts but discards when logs are disabled" do
    Setting.instance.update!(store_logs: false)
    with_tuber_stub do |calls|
      post "/v1/logs", params: @payload.to_json,
        headers: {"Content-Type" => "application/json", "Authorization" => "Bearer #{@project.public_key}"}
      assert_response :success
      assert_empty calls
    end
  ensure
    Setting.instance.update!(store_logs: true)
  end
end
