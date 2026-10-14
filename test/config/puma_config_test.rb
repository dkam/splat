# frozen_string_literal: true

require "test_helper"
require "puma"
require "puma/configuration"
require "puma/server"

# config/puma.rb, read as Puma reads it.
class PumaConfigTest < ActiveSupport::TestCase
  setup do
    @options = Puma::Configuration.new({}, {}, ENV) { |_user, file| file.load Rails.root.join("config/puma.rb").to_s }
      .tap(&:clamp).options
  end

  # Rails parses a body typed as JSON (OTLP logs, /store/) for its request log
  # before any controller runs, so the ingest endpoints' own 20 MB check comes
  # too late for those. Puma refuses before Rails sees the request.
  test "refuses a body over the ingest limit before the app sees it" do
    assert_equal Ingest::Decompression::MAX_SENT, @options[:http_content_length_limit]

    seen = []
    app = ->(env) {
      seen << env["CONTENT_LENGTH"]
      [200, {}, ["ok"]]
    }
    server = Puma::Server.new(app, nil, http_content_length_limit: @options[:http_content_length_limit], log_writer: Puma::LogWriter.null)
    port = server.add_tcp_listener("127.0.0.1", 0).addr[1]
    server.run

    assert_equal "413", status_for(port, Ingest::Decompression::MAX_SENT + 1)
    assert_equal "200", status_for(port, 2, "{}")
    assert_equal ["2"], seen
  ensure
    server&.stop(true)
  end

  private

  # Only the headers of a big body: Puma answers from the Content-Length.
  def status_for(port, content_length, body = "")
    socket = TCPSocket.new("127.0.0.1", port)
    socket.write("POST /v1/logs HTTP/1.1\r\nHost: splat\r\nContent-Type: application/json\r\n" \
      "Content-Length: #{content_length}\r\nConnection: close\r\n\r\n#{body}")
    socket.gets.to_s.split[1]
  ensure
    socket&.close
  end
end
