# frozen_string_literal: true

require "test_helper"

class Api::EnvelopesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Test Project", slug: "test-project", public_key: "test-public-key-123")
    @valid_envelope = create_sample_envelope
  end

  test "successfully processes envelope with query parameter authentication" do
    post "/api/#{@project.slug}/envelope?sentry_key=#{@project.public_key}",
         headers: { 'Content-Type' => 'application/octet-stream' },
         params: @valid_envelope

    assert_response :success
  end

  test "successfully processes envelope with header authentication" do
    post "/api/#{@project.id}/envelope?sentry_key=#{@project.public_key}",
         headers: {
           'Content-Type' => 'application/octet-stream',
           'X-Sentry-Auth' => "Sentry sentry_key=#{@project.public_key}, sentry_version=7"
         },
         params: @valid_envelope

    assert_response :success
  end

  test "rejects envelope with invalid public key in query params" do
    post "/api/#{@project.slug}/envelope?sentry_key=invalid-key",
         headers: { 'Content-Type' => 'application/octet-stream' },
         params: @valid_envelope

    assert_response :unauthorized
  end

  test "rejects envelope with invalid public key in header" do
    post "/api/#{@project.slug}/envelope?sentry_key=invalid-key",
         headers: {
           'Content-Type' => 'application/octet-stream',
           'X-Sentry-Auth' => "Sentry sentry_key=invalid-key, sentry_version=7"
         },
         params: @valid_envelope

    assert_response :unauthorized
  end

  test "rejects envelope with no authentication" do
    post "/api/#{@project.slug}/envelope",
         headers: { 'Content-Type' => 'application/octet-stream' },
         params: @valid_envelope

    assert_response :unauthorized
  end

  test "returns unauthorized for nonexistent project even with valid key" do
    post "/api/nonexistent/envelope?sentry_key=#{@project.public_key}",
         headers: { 'Content-Type' => 'application/octet-stream' },
         params: @valid_envelope

    assert_response :unauthorized
  end

  test "handles Bearer token authentication" do
    post "/api/#{@project.slug}/envelope",
         headers: {
           'Content-Type' => 'application/octet-stream',
           'Authorization' => "Bearer #{@project.public_key}"
         },
         params: @valid_envelope

    assert_response :success
  end

  private

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