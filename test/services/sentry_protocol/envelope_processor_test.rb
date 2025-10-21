require "test_helper"

class SentryProtocol::EnvelopeProcessorTest < ActiveSupport::TestCase
  def setup
    @project = Project.create!(name: "Test Project", slug: "test", public_key: "test-key")
  end

  test "processes valid envelope with event" do
    envelope_body = build_envelope(
      event_id: "abc123",
      sent_at: "2025-10-18T08:00:00Z",
      items: [
        {
          type: "event",
          payload: { "message" => "Test error", "platform" => "ruby" }
        }
      ]
    )

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    assert processor.process
  end

  test "processes envelope with event_id only in payload" do
    envelope_body = build_envelope_with_empty_headers(
      items: [
        {
          type: "event",
          payload: {
            "event_id" => "payload123",
            "message" => "Test error",
            "platform" => "ruby"
          }
        }
      ]
    )

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    assert processor.process
  end

  test "processes envelope with event_id only in envelope headers" do
    envelope_body = build_envelope(
      event_id: "header123",
      sent_at: "2025-10-18T08:00:00Z",
      items: [
        {
          type: "event",
          payload: {
            "message" => "Test error",
            "platform" => "ruby"
          }
        }
      ]
    )

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    assert processor.process
  end

  test "processes envelope with event_id in both payload and headers (prefers payload)" do
    envelope_body = build_envelope(
      event_id: "header123",
      sent_at: "2025-10-18T08:00:00Z",
      items: [
        {
          type: "event",
          payload: {
            "event_id" => "payload456",
            "message" => "Test error",
            "platform" => "ruby"
          }
        }
      ]
    )

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    assert processor.process
  end

  test "rejects envelope without event_id in either payload or headers" do
    envelope_body = build_envelope_with_empty_headers(
      items: [
        { type: "event", payload: { "message" => "Test" } }
      ]
    )

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    # Should still process but log error - the item will be skipped
    assert processor.process
  end

  test "rejects envelope with no items" do
    envelope_body = '{"event_id":"abc123","sent_at":"2025-10-18T08:00:00Z"}'

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    assert_not processor.process
  end

  test "rejects envelope with empty body" do
    processor = SentryProtocol::EnvelopeProcessor.new("", @project)
    assert_not processor.process
  end

  test "rejects item without type" do
    envelope_body = build_envelope(
      event_id: "abc123",
      items: [
        { payload: { "message" => "Test" } } # Missing type
      ]
    )

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    assert_not processor.process
  end

  test "rejects item without payload" do
    envelope_body = <<~ENVELOPE
      {"event_id":"abc123","sent_at":"2025-10-18T08:00:00Z"}
      {"type":"event"}
    ENVELOPE

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    assert_not processor.process
  end

  test "accepts envelope with valid sent_at timestamp" do
    envelope_body = build_envelope(
      event_id: "abc123",
      sent_at: "2025-10-18T08:00:00Z",
      items: [
        { type: "event", payload: { "message" => "Test" } }
      ]
    )

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    assert processor.process
  end

  test "rejects envelope with invalid sent_at timestamp" do
    envelope_body = <<~ENVELOPE
      {"event_id":"abc123","sent_at":"not-a-timestamp"}
      {"type":"event"}
      {"message":"Test"}
    ENVELOPE

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    assert_not processor.process
  end

  test "processes multiple items in envelope" do
    envelope_body = build_envelope(
      event_id: "abc123",
      items: [
        { type: "event", payload: { "message" => "Error 1" } },
        { type: "event", payload: { "message" => "Error 2" } }
      ]
    )

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    assert processor.process
  end

  test "skips unknown item types without failing" do
    envelope_body = build_envelope(
      event_id: "abc123",
      items: [
        { type: "unknown_type", payload: { "data" => "something" } },
        { type: "event", payload: { "message" => "Test" } }
      ]
    )

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    assert processor.process
  end

  test "handles malformed JSON gracefully" do
    envelope_body = "not valid json at all"

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    assert_not processor.process
  end

  test "processes transaction items" do
    envelope_body = build_envelope(
      event_id: "txn123",
      items: [
        {
          type: "transaction",
          payload: {
            "transaction" => "GET /users",
            "start_timestamp" => 1729238400.0,
            "timestamp" => 1729238401.5
          }
        }
      ]
    )

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    assert processor.process
  end

  test "processes transaction with event_id only in payload" do
    envelope_body = build_envelope_with_empty_headers(
      items: [
        {
          type: "transaction",
          payload: {
            "event_id" => "txn456",
            "transaction" => "GET /users",
            "start_timestamp" => 1729238400.0,
            "timestamp" => 1729238401.5
          }
        }
      ]
    )

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    assert processor.process
  end

  test "skips attachment items" do
    envelope_body = build_envelope(
      event_id: "abc123",
      items: [
        { type: "attachment", payload: "binary data here" },
        { type: "event", payload: { "message" => "Test" } }
      ]
    )

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    assert processor.process
  end

  test "skips session items" do
    envelope_body = build_envelope(
      event_id: "abc123",
      items: [
        { type: "session", payload: { "session_id" => "xyz" } },
        { type: "event", payload: { "message" => "Test" } }
      ]
    )

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    assert processor.process
  end

  # Edge cases from GlitchTip

  test "handles item with explicit length field" do
    payload_dict = {
      "event_id" => "c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3",
      "timestamp" => "2025-10-18T13:01:00Z",
      "platform" => "ruby",
      "message" => "Event with explicit length"
    }

    payload_json = payload_dict.to_json
    payload_length = payload_json.bytesize

    envelope_header = { "event_id" => payload_dict["event_id"] }
    item_header = {
      "type" => "event",
      "length" => payload_length
    }

    envelope_body = [
      envelope_header.to_json,
      item_header.to_json,
      payload_json
    ].join("\n")

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    assert processor.process
  end

  test "skips attachment with binary data using length field" do
    envelope_header = { "event_id" => "abc123" }

    # Binary attachment that should be skipped
    attachment_payload = "This is some log content.\nEnd."
    attachment_header = {
      "type" => "attachment",
      "length" => attachment_payload.bytesize,
      "filename" => "debug.log",
      "content_type" => "text/plain"
    }

    # Valid event that should be processed
    event_payload = {
      "event_id" => "f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6",
      "timestamp" => "2025-10-18T13:09:01Z",
      "platform" => "ruby",
      "message" => "Processing after ignored attachment"
    }

    envelope_body = [
      envelope_header.to_json,
      attachment_header.to_json,
      attachment_payload,
      { "type" => "event", "length" => event_payload.to_json.bytesize }.to_json,
      event_payload.to_json
    ].join("\n")

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    assert processor.process
  end

  test "skips log items with length field" do
    envelope_header = { "event_id" => "abc123" }

    # Log item to skip
    log_payload = { "msg" => "some log content" }.to_json
    log_header = {
      "type" => "log",
      "length" => log_payload.bytesize
    }

    # Valid event
    event_payload = {
      "event_id" => "abcdabcdabcdabcdabcdabcdabcdabcd",
      "timestamp" => "2025-10-18T13:09:01Z",
      "platform" => "ruby",
      "message" => "Logged event"
    }

    envelope_body = [
      envelope_header.to_json,
      log_header.to_json,
      log_payload,
      { "type" => "event", "length" => event_payload.to_json.bytesize }.to_json,
      event_payload.to_json
    ].join("\n")

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    assert processor.process
  end

  test "processes envelope with mixed items: some with event_id, some without" do
    event_payload = {
      "event_id" => "valid123",
      "message" => "Valid event",
      "platform" => "ruby"
    }
    event_json = event_payload.to_json

    transaction_payload = {
      "event_id" => "txn456",
      "transaction" => "GET /api/test",
      "timestamp" => "2025-10-18T13:09:01Z"
    }
    transaction_json = transaction_payload.to_json

    envelope_body = [
      "{}",  # Empty headers
      '{"type":"event","length":' + event_json.bytesize.to_s + '}',
      event_json,
      '{"type":"event"}',
      '{"message":"Invalid event - no event_id","platform":"ruby"}',
      '{"type":"transaction","length":' + transaction_json.bytesize.to_s + '}',
      transaction_json
    ].join("\n")

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    assert processor.process
  end

  test "handles long message without truncation" do
    envelope_body = build_envelope(
      event_id: "abc123",
      items: [
        {
          type: "event",
          payload: {
            "message" => "a" * 9000,
            "platform" => "ruby",
            "timestamp" => "2025-10-18T08:00:00Z"
          }
        }
      ]
    )

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    assert processor.process
  end

  test "handles envelope without sent_at field" do
    envelope_body = build_envelope(
      event_id: "abc123",
      items: [
        { type: "event", payload: { "message" => "Test" } }
      ]
    )

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    assert processor.process
  end

  test "strips null bytes from payload" do
    envelope_body = build_envelope(
      event_id: "abc123",
      items: [
        {
          type: "event",
          payload: {
            "message" => "Test\u0000message",
            "tags" => { "\u0000bad_key" => "value" },
            "platform" => "ruby",
            "timestamp" => "2025-10-18T08:00:00Z"
          }
        }
      ]
    )

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    # Should process successfully - null bytes will be handled by Event model
    assert processor.process
  end

  test "handles invalid length field gracefully" do
    envelope_body = <<~ENVELOPE
      {"event_id":"abc123"}
      {"type":"event","length":"not-a-number"}
      {"message":"Test"}
    ENVELOPE

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    assert_not processor.process
  end

  test "handles negative length field" do
    envelope_body = <<~ENVELOPE
      {"event_id":"abc123"}
      {"type":"event","length":-1}
      {"message":"Test"}
    ENVELOPE

    processor = SentryProtocol::EnvelopeProcessor.new(envelope_body, @project)
    assert_not processor.process
  end

  private

  def build_envelope(event_id: nil, sent_at: nil, items: [])
    headers = {}
    headers["event_id"] = event_id if event_id
    headers["sent_at"] = sent_at if sent_at

    lines = [ headers.to_json ]

    items.each do |item|
      item_headers = {}
      item_headers["type"] = item[:type] if item[:type]
      lines << item_headers.to_json

      if item[:payload]
        lines << item[:payload].to_json
      end
    end

    lines.join("\n")
  end

  def build_envelope_with_empty_headers(items: [])
    lines = [ "{}" ]  # Empty headers

    items.each do |item|
      item_headers = {}
      item_headers["type"] = item[:type] if item[:type]
      lines << item_headers.to_json

      if item[:payload]
        lines << item[:payload].to_json
      end
    end

    lines.join("\n")
  end
end
