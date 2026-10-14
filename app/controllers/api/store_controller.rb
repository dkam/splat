# frozen_string_literal: true

require "base64"

# POST /api/:project_id/store/ — where Sentry's clients posted a single event
# before envelopes. The event is made a one-item envelope and goes the
# envelope's way from there: queued, forwarded (as an envelope), and answered
# 503 or 413 alike.
class Api::StoreController < Api::EnvelopesController
  private

  def envelope(body)
    json = decoded(body)
    event = JSON.parse(json)
    raise Ingest::Decompression::Unreadable, "store: not a JSON object" unless event.is_a?(Hash)

    @event_id = event["event_id"].presence || SecureRandom.hex(16)
    type = (event["type"] == "transaction") ? "transaction" : "event"
    [{event_id: @event_id}.to_json, {type: type, length: json.bytesize}.to_json, json].join("\n")
  rescue JSON::ParserError => e
    raise Ingest::Decompression::Unreadable, "store: #{e.message}"
  end

  # As Relay reads it: JSON as sent, or base64 of JSON, or base64 of
  # zlib-compressed JSON — what raven-ruby and raven-python sent.
  def decoded(body)
    return body if body.empty? || body.start_with?("{")

    binary = Base64.strict_decode64(body)
    binary.start_with?("{") ? binary : Ingest::Decompression.inflate(binary)
  rescue ArgumentError
    raise Ingest::Decompression::Unreadable, "store: neither JSON nor base64"
  end

  def envelope_content_type = "application/x-sentry-envelope"

  def accepted = render(json: {id: @event_id})
end
