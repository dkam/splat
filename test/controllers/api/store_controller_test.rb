# frozen_string_literal: true

require "test_helper"

# The endpoint Sentry's clients posted a single event to before envelopes:
# raven-ruby, raven-python, raven-js and the third-party clients that never
# moved on.
class Api::StoreControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Store Project", slug: "store-project", public_key: "store-key-123")
    @event = {"event_id" => "a" * 32, "message" => "Card 4412 declined", "level" => "error", "platform" => "ruby"}
  end

  test "queues an event posted as JSON, and answers with its id" do
    queued = capture_tuber_puts { post_store(@event.to_json) }

    assert_response :success
    assert_equal({"id" => "a" * 32}, response.parsed_body)
    assert_equal [[Ingest::Tuber::EVENTS_TUBE, "a" * 32]], queued.map { [it[0], it[1][:event_id]] }
    assert_equal "Card 4412 declined", queued.first[1][:payload]["message"]
  end

  # raven-ruby: Base64.strict_encode64(Zlib::Deflate.deflate(json)).
  test "reads an event sent as base64 of zlib, as the raven clients sent it" do
    queued = capture_tuber_puts { post_store(Base64.strict_encode64(Zlib::Deflate.deflate(@event.to_json))) }

    assert_response :success
    assert_equal ["a" * 32], queued.map { it[1][:event_id] }
  end

  test "reads an event sent as base64 of JSON" do
    queued = capture_tuber_puts { post_store(Base64.strict_encode64(@event.to_json)) }

    assert_response :success
    assert_equal ["a" * 32], queued.map { it[1][:event_id] }
  end

  test "reads an event sent with Content-Encoding: gzip" do
    queued = capture_tuber_puts { post_store(compress("gzip", @event.to_json), "Content-Encoding" => "gzip") }

    assert_response :success
    assert_equal ["a" * 32], queued.map { it[1][:event_id] }
  end

  test "gives an event without an id one, and answers with it" do
    queued = capture_tuber_puts { post_store(@event.except("event_id").to_json) }

    assert_response :success
    id = response.parsed_body["id"]
    assert_match(/\A\h{32}\z/, id)
    assert_equal [id], queued.map { it[1][:event_id] }
  end

  test "queues a transaction as a transaction" do
    transaction = {"event_id" => "b" * 32, "type" => "transaction", "transaction" => "POST /checkout",
                   "start_timestamp" => 1_700_000_000.0, "timestamp" => 1_700_000_000.5, "spans" => []}
    queued = capture_tuber_puts { post_store(transaction.to_json) }

    assert_response :success
    assert_equal [Ingest::Tuber::TRANSACTIONS_TUBE], queued.map(&:first)
  end

  test "answers 503 when tuber can't be reached" do
    with_stub(Ingest::Tuber, :put, ->(*, **) { raise Errno::ECONNREFUSED }) { post_store(@event.to_json) }

    assert_response :service_unavailable
  end

  test "answers 413 to zlib that decompresses past 100 MB" do
    zeros = Zlib::Deflate.new
    bomb = +""
    101.times { bomb << zeros.deflate("\0" * 1.megabyte) }
    bomb << zeros.finish
    queued = capture_tuber_puts { post_store(Base64.strict_encode64(bomb)) }

    assert_response :content_too_large
    assert_empty queued
  end

  test "drops with a 200 a body that is neither JSON nor base64" do
    queued = capture_tuber_puts { post_store("not an event") }

    assert_response :success
    assert_empty queued
  end

  test "rejects a wrong key" do
    post "/api/#{@project.slug}/store/?sentry_key=wrong", params: @event.to_json, headers: {"Content-Type" => "application/json"}

    assert_response :unauthorized
  end

  test "carries the rate limits of streams switched off" do
    Setting.instance.update!(store_logs: false)
    capture_tuber_puts { post_store(@event.to_json) }

    assert_equal "60:log_item:organization:disabled", response.headers["X-Sentry-Rate-Limits"]
  end

  # A forward target is sent an envelope, whatever the client sent here.
  test "forwards the event as an envelope" do
    @project.update!(forward_dsns: ["https://k@downstream.example/9"])
    queued = capture_tuber_puts { post_store(@event.to_json) }

    forwarded = queued.find { it[0] == Ingest::Tuber::FORWARD_TUBE }[1]
    assert_equal "application/x-sentry-envelope", forwarded[:content_type]
    header, item, payload = Base64.strict_decode64(forwarded[:body]).split("\n")
    assert_equal "a" * 32, JSON.parse(header)["event_id"]
    assert_equal({"type" => "event", "length" => payload.bytesize}, JSON.parse(item))
    assert_equal @event, JSON.parse(payload)
  end

  private

  def post_store(body, headers = {})
    post "/api/#{@project.slug}/store/",
      params: body,
      headers: {"Content-Type" => "application/json", "X-Sentry-Auth" => "Sentry sentry_key=#{@project.public_key}, sentry_version=7"}.merge(headers)
  end

  def capture_tuber_puts
    calls = []
    with_stub(Ingest::Tuber, :put, ->(tube, payload, **) { calls << [tube, payload] }) { yield }
    calls
  end
end
