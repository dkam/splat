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

  test "forward is a no-op when forwarding is not configured" do
    Setting.instance.update!(forward_dsn: nil)

    assert_nothing_raised do
      EnvelopeForwarder.forward("raw-body", project: @project)
    end
  end
end
