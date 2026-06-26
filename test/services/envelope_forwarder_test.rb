# frozen_string_literal: true

require "test_helper"

class EnvelopeForwarderTest < ActiveSupport::TestCase
  setup do
    @project = projects(:one)  # slug=project-one, public_key=test-public-key-one
  end

  test "parse_dsn returns scheme/host/port and ignores embedded key + project id" do
    target = EnvelopeForwarder.parse_dsn("https://target-key@target.example/target-project")

    assert_equal "https", target.scheme
    assert_equal "target.example", target.host
    assert_nil target.port
  end

  test "parse_dsn keeps non-default port" do
    target = EnvelopeForwarder.parse_dsn("http://x@target.example:8080/anything")

    assert_equal 8080, target.port
  end

  test "parse_dsn raises on invalid scheme" do
    assert_raises(EnvelopeForwarder::InvalidDsn) do
      EnvelopeForwarder.parse_dsn("ftp://x@target.example/1")
    end
  end

  test "parse_dsn raises on missing host" do
    assert_raises(EnvelopeForwarder::InvalidDsn) do
      EnvelopeForwarder.parse_dsn("https:///path")
    end
  end

  test "outbound_request uses target host but project's slug + public_key" do
    forward_dsn = "https://target-key@target.example/target-project"

    req = EnvelopeForwarder.outbound_request(forward_dsn, @project)

    assert_equal "https://target.example/api/project-one/envelope/", req[:url]
    assert_includes req[:auth_header], "sentry_key=test-public-key-one"
    refute_includes req[:url], "target-project"
    refute_includes req[:auth_header], "target-key"
  end

  test "outbound_request includes port when non-default" do
    req = EnvelopeForwarder.outbound_request("http://x@target.example:8080/anything", @project)

    assert_equal "http://target.example:8080/api/project-one/envelope/", req[:url]
  end

  test "forward is a no-op when the project has no forward DSNs" do
    @project.update!(forward_dsns: [])

    put_calls = capture_tuber_puts do
      EnvelopeForwarder.forward("raw-body", project: @project)
    end

    assert_empty put_calls
  end

  test "forward enqueues a base64'd job to the forward tube" do
    @project.update!(forward_dsns: ["https://k@a.example/1", "https://k@b.example/2"])

    put_calls = capture_tuber_puts do
      EnvelopeForwarder.forward("raw-body", project: @project, content_type: "application/x-sentry-envelope")
    end

    assert_equal 1, put_calls.size
    tube, payload = put_calls.first
    assert_equal Ingest::Tuber::FORWARD_TUBE, tube
    assert_equal @project.id, payload[:project_id]
    assert_equal ["https://k@a.example/1", "https://k@b.example/2"], payload[:dsns]
    assert_equal "raw-body", Base64.strict_decode64(payload[:body])
    assert_equal "application/x-sentry-envelope", payload[:content_type]
  end

  test "forward never raises into the ingest path" do
    @project.update!(forward_dsns: ["https://k@a.example/1"])

    Ingest::Tuber.singleton_class.define_method(:put) { |*, **| raise "boom" }
    begin
      assert_nothing_raised do
        EnvelopeForwarder.forward("raw-body", project: @project)
      end
    ensure
      Ingest::Tuber.singleton_class.remove_method(:put)
    end
  end

  test "deliver returns false (not raise) on an invalid DSN" do
    assert_equal false, EnvelopeForwarder.deliver("raw-body", dsn: "ftp://x@nope/1", project: @project)
  end

  test "outbound_request includes SPLAT_FORWARDER_TOKEN when set" do
    previous = ENV["SPLAT_FORWARDER_TOKEN"]
    ENV["SPLAT_FORWARDER_TOKEN"] = "shared-secret"
    begin
      req = EnvelopeForwarder.outbound_request("https://x@target.example/y", @project)
      assert_equal "shared-secret", req[:forwarder_token]
    ensure
      ENV["SPLAT_FORWARDER_TOKEN"] = previous
    end
  end

  test "outbound_request returns nil forwarder_token when env not set" do
    previous = ENV["SPLAT_FORWARDER_TOKEN"]
    ENV.delete("SPLAT_FORWARDER_TOKEN")
    begin
      req = EnvelopeForwarder.outbound_request("https://x@target.example/y", @project)
      assert_nil req[:forwarder_token]
    ensure
      ENV["SPLAT_FORWARDER_TOKEN"] = previous if previous
    end
  end

  private

  # Capture Ingest::Tuber.put calls as [tube, payload] pairs without touching
  # beanstalkd. Mirrors the override pattern used in the processor tests.
  def capture_tuber_puts
    calls = []
    Ingest::Tuber.singleton_class.define_method(:put) { |tube, payload, **| calls << [tube, payload] }
    begin
      yield
    ensure
      Ingest::Tuber.singleton_class.remove_method(:put)
    end
    calls
  end
end
