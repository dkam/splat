# frozen_string_literal: true

require "test_helper"

class Api::EnvelopesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Test Project", slug: "test-project", public_key: "test-public-key-123")
    @valid_envelope = create_sample_envelope
  end

  test "successfully processes envelope with query parameter authentication" do
    queued = capture_tuber_puts do
      post "/api/#{@project.slug}/envelope?sentry_key=#{@project.public_key}",
        headers: {"Content-Type" => "application/octet-stream"},
        params: @valid_envelope
    end

    assert_response :success
    assert_equal [Ingest::Tuber::EVENTS_TUBE], queued.map(&:first)
  end

  test "successfully processes envelope with header authentication" do
    queued = capture_tuber_puts do
      post "/api/#{@project.id}/envelope?sentry_key=#{@project.public_key}",
        headers: {
          "Content-Type" => "application/octet-stream",
          "X-Sentry-Auth" => "Sentry sentry_key=#{@project.public_key}, sentry_version=7"
        },
        params: @valid_envelope
    end

    assert_response :success
    assert_equal [Ingest::Tuber::EVENTS_TUBE], queued.map(&:first)
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
    queued = capture_tuber_puts do
      post "/api/#{@project.slug}/envelope",
        headers: {
          "Content-Type" => "application/octet-stream",
          "Authorization" => "Bearer #{@project.public_key}"
        },
        params: @valid_envelope
    end

    assert_response :success
    assert_equal [Ingest::Tuber::EVENTS_TUBE], queued.map(&:first)
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

  # Kept on disk until tuber is back, so the envelope isn't lost.
  test "spools the envelope when tuber can't be reached, and answers 200" do
    with_stub(Ingest::Tuber, :put, ->(*, **) { raise Errno::ECONNREFUSED }) do
      post_envelope
    end

    assert_response :success
    assert_equal 1, Ingest::Spool.stats[:jobs]
  end

  test "spools the forward too when tuber can't be reached" do
    @project.update!(forward_dsns: ["https://k@downstream.example/9"])
    with_stub(Ingest::Tuber, :put, ->(*, **) { raise Errno::ECONNREFUSED }) do
      post_envelope
    end

    assert_response :success
    assert_equal 2, Ingest::Spool.stats[:jobs]
  end

  # An SDK told 200 counts the envelope as delivered. It wasn't.
  test "answers 503 when tuber can't be reached and the spool is full" do
    Ingest::Spool.max_bytes = 0
    with_stub(Ingest::Tuber, :put, ->(*, **) { raise Errno::ECONNREFUSED }) do
      post_envelope
    end

    assert_response :service_unavailable
  end

  # Tuber is up and said no; the same envelope sent again would be refused again.
  test "answers 200 to an item too big for tuber" do
    reports = []
    with_stub(Sentry, :capture_message, ->(*, **kw) { reports << kw[:fingerprint] }) do
      with_stub(Ingest::Tuber, :put, ->(*, **) { raise ::Tuber::JobTooBigError.new("JOB_TOO_BIG", "put") }) do
        post_envelope
      end
    end

    assert_response :success
    assert_equal [["ingest", "job_too_big", "event"]], reports
  end

  test "says which streams are switched off, as Sentry rate limits" do
    Setting.instance.update!(store_events: false, store_transactions: false, store_logs: false)
    capture_tuber_puts { post_envelope }

    assert_response :success
    assert_equal "60:error;transaction;log_item:organization:disabled", response.headers["X-Sentry-Rate-Limits"]
  end

  test "says nothing of rate limits with every stream on" do
    Setting.instance.update!(store_events: true, store_transactions: true, store_logs: true)
    capture_tuber_puts { post_envelope }

    assert_response :success
    assert_nil response.headers["X-Sentry-Rate-Limits"]
  end

  # The envelope goes on whole to the forward targets, which may store it all.
  test "doesn't rate-limit a project that forwards" do
    Setting.instance.update!(store_logs: false)
    @project.update!(forward_dsns: ["https://k@downstream.example/9"])
    capture_tuber_puts { post_envelope }

    assert_response :success
    assert_nil response.headers["X-Sentry-Rate-Limits"]
  end

  # CVE-2026-111497: libbrotli up to 1.2.0 can write out of bounds decoding
  # a crafted stream, and no brotli gem bundles 1.2.1 yet. Refused on the
  # header alone, never decoded; SDKs drop it rather than retry.
  ["br", "BR", "gzip, br"].each do |encoding|
    test "refuses with a 415, undecoded, a body sent with Content-Encoding: #{encoding}" do
      queued = capture_tuber_puts { post_envelope("not decoded", encoding) }

      assert_response :unsupported_media_type
      assert_empty queued
    end
  end

  %w[gzip deflate zstd].each do |encoding|
    test "reads an envelope sent with Content-Encoding: #{encoding}" do
      queued = capture_tuber_puts { post_envelope(compress(encoding, @valid_envelope), encoding) }

      assert_response :success
      assert_equal [Ingest::Tuber::EVENTS_TUBE], queued.map(&:first)
    end

    # Sentry's own limit, so nothing an SDK would send to Sentry is refused.
    test "answers 413 to an envelope over 100 MB once decompressed from #{encoding}" do
      queued = capture_tuber_puts { post_envelope(compressed_zeros(encoding, 101.megabytes), encoding) }

      assert_response :content_too_large
      assert_empty queued
    end

    # Sent again, it still couldn't be read.
    test "drops with a 200 a body Content-Encoding: #{encoding} can't undo" do
      queued = capture_tuber_puts { post_envelope("not #{encoding} at all", encoding) }

      assert_response :success
      assert_empty queued
    end
  end

  # Rails would parse a body typed as JSON into params, and fail on gzip.
  test "reads a compressed envelope sent as Content-Type: application/json" do
    queued = capture_tuber_puts do
      post "/api/#{@project.slug}/envelope?sentry_key=#{@project.public_key}",
        headers: {"Content-Type" => "application/json", "Content-Encoding" => "gzip"},
        params: compress("gzip", @valid_envelope)
    end

    assert_response :success
    assert_equal [Ingest::Tuber::EVENTS_TUBE], queued.map(&:first)
  end

  test "answers 413 to a body over 20 MB as sent" do
    queued = capture_tuber_puts { post_envelope(@valid_envelope + "\n" + (" " * 20.megabytes)) }

    assert_response :content_too_large
    assert_empty queued
  end

  private

  def post_envelope(body = @valid_envelope, encoding = nil)
    headers = {"Content-Type" => "application/octet-stream", "Content-Encoding" => encoding}.compact
    post "/api/#{@project.slug}/envelope?sentry_key=#{@project.public_key}", headers: headers, params: body
  end

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

    item_payload = {
      "timestamp" => timestamp,
      "message" => "Test error message",
      "level" => "error",
      "platform" => "ruby"
    }.to_json

    item_headers = {
      "type" => "event",
      "length" => item_payload.bytesize
    }.to_json

    [envelope_headers, item_headers, item_payload].join("\n")
  end
end
