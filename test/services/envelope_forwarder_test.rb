# frozen_string_literal: true

require "test_helper"

class EnvelopeForwarderTest < ActiveSupport::TestCase
  setup do
    @project = projects(:one)  # slug=project-one, public_key=test-public-key-one
  end

  test "parse_dsn extracts scheme/host/port/key/project" do
    target = EnvelopeForwarder.parse_dsn("https://target-key@target.example/target-project")

    assert_equal "https", target.scheme
    assert_equal "target.example", target.host
    assert_nil target.port
    assert_equal "target-key", target.key
    assert_equal "target-project", target.project
  end

  test "parse_dsn keeps non-default port" do
    target = EnvelopeForwarder.parse_dsn("http://k@target.example:8080/p")

    assert_equal 8080, target.port
  end

  test "parse_dsn raises on invalid scheme" do
    assert_raises(EnvelopeForwarder::InvalidDsn) do
      EnvelopeForwarder.parse_dsn("ftp://k@target.example/1")
    end
  end

  test "parse_dsn raises on missing host" do
    assert_raises(EnvelopeForwarder::InvalidDsn) do
      EnvelopeForwarder.parse_dsn("https:///path")
    end
  end

  test "parse_dsn raises when the public key is missing" do
    assert_raises(EnvelopeForwarder::InvalidDsn) do
      EnvelopeForwarder.parse_dsn("https://target.example/target-project")
    end
  end

  test "parse_dsn raises when the project is missing (host-only)" do
    assert_raises(EnvelopeForwarder::InvalidDsn) do
      EnvelopeForwarder.parse_dsn("https://target-key@target.example")
    end
  end

  test "outbound_request targets the DSN's own project + key (relay)" do
    req = EnvelopeForwarder.outbound_request("https://target-key@target.example/target-project")

    assert_equal "https://target.example/api/target-project/envelope/", req[:url]
    assert_includes req[:auth_header], "sentry_key=target-key"
  end

  test "outbound_request includes port when non-default" do
    req = EnvelopeForwarder.outbound_request("http://k@target.example:8080/p")

    assert_equal "http://target.example:8080/api/p/envelope/", req[:url]
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

    with_stub(Ingest::Tuber, :put, ->(*, **) { raise "boom" }) do
      assert_nothing_raised do
        EnvelopeForwarder.forward("raw-body", project: @project)
      end
    end
  end

  test "deliver returns false (not raise) on an invalid DSN" do
    assert_equal false, EnvelopeForwarder.deliver("raw-body", dsn: "ftp://x@nope/1", project: @project)
  end

  private

  # Capture Ingest::Tuber.put calls as [tube, payload] pairs without touching
  # beanstalkd.
  def capture_tuber_puts
    calls = []
    with_stub(Ingest::Tuber, :put, ->(tube, payload, **) { calls << [tube, payload] }) { yield }
    calls
  end
end
