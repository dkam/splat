# frozen_string_literal: true

require "test_helper"

class Api::EnvelopesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Test Project", slug: "test-project", public_key: "test-public-key-123")
    @valid_envelope = create_sample_envelope
  end

  test "successfully processes envelope with query parameter authentication" do
    post "/api/#{@project.slug}/envelope?sentry_key=#{@project.public_key}",
      headers: {"Content-Type" => "application/octet-stream"},
      params: @valid_envelope

    assert_response :success
  end

  test "successfully processes envelope with header authentication" do
    post "/api/#{@project.id}/envelope?sentry_key=#{@project.public_key}",
      headers: {
        "Content-Type" => "application/octet-stream",
        "X-Sentry-Auth" => "Sentry sentry_key=#{@project.public_key}, sentry_version=7"
      },
      params: @valid_envelope

    assert_response :success
  end

  test "rejects envelope with invalid public key in query params" do
    post "/api/#{@project.slug}/envelope?sentry_key=invalid-key",
      headers: {"Content-Type" => "application/octet-stream"},
      params: @valid_envelope

    assert_response :unauthorized
  end

  test "rejects envelope with invalid public key in header" do
    post "/api/#{@project.slug}/envelope?sentry_key=invalid-key",
      headers: {
        "Content-Type" => "application/octet-stream",
        "X-Sentry-Auth" => "Sentry sentry_key=invalid-key, sentry_version=7"
      },
      params: @valid_envelope

    assert_response :unauthorized
  end

  test "rejects envelope with no authentication" do
    post "/api/#{@project.slug}/envelope",
      headers: {"Content-Type" => "application/octet-stream"},
      params: @valid_envelope

    assert_response :unauthorized
  end

  test "returns unauthorized for nonexistent project even with valid key" do
    post "/api/nonexistent/envelope?sentry_key=#{@project.public_key}",
      headers: {"Content-Type" => "application/octet-stream"},
      params: @valid_envelope

    assert_response :unauthorized
  end

  test "handles Bearer token authentication" do
    post "/api/#{@project.slug}/envelope",
      headers: {
        "Content-Type" => "application/octet-stream",
        "Authorization" => "Bearer #{@project.public_key}"
      },
      params: @valid_envelope

    assert_response :success
  end

  test "enqueues a forward job when the project has forward DSNs" do
    @project.update!(forward_dsns: ["https://k@downstream.example/9"])

    forward_puts = capture_tuber_puts do
      post "/api/#{@project.slug}/envelope?sentry_key=#{@project.public_key}",
        headers: {"Content-Type" => "application/octet-stream"},
        params: @valid_envelope
    end.select { |tube, _| tube == Ingest::Tuber::FORWARD_TUBE }

    assert_response :success
    assert_equal 1, forward_puts.size
    payload = forward_puts.first[1]
    assert_equal @project.id, payload[:project_id]
    assert_equal ["https://k@downstream.example/9"], payload[:dsns]
  end

  test "does not enqueue a forward job when the project has no forward DSNs" do
    forward_puts = capture_tuber_puts do
      post "/api/#{@project.slug}/envelope?sentry_key=#{@project.public_key}",
        headers: {"Content-Type" => "application/octet-stream"},
        params: @valid_envelope
    end.select { |tube, _| tube == Ingest::Tuber::FORWARD_TUBE }

    assert_response :success
    assert_empty forward_puts
  end

  private

  def capture_tuber_puts
    calls = []
    with_stub(Ingest::Tuber, :put, ->(tube, payload, **) { calls << [tube, payload] }) { yield }
    calls
  end

  def create_sample_envelope
    # Create a minimal valid Sentry envelope
    event_id = SecureRandom.uuid
    timestamp = Time.current.iso8601

    envelope_headers = {
      "event_id" => event_id,
      "sent_at" => timestamp
    }.to_json

    item_headers = {
      "type" => "event",
      "length" => 100
    }.to_json

    item_payload = {
      "timestamp" => timestamp,
      "message" => "Test error message",
      "level" => "error",
      "platform" => "ruby"
    }.to_json

    [envelope_headers, item_headers, item_payload].join("\n")
  end
end
