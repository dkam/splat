# frozen_string_literal: true

require "test_helper"

class NtfyNotifierTest < ActiveSupport::TestCase
  setup do
    @project = projects(:one)
    @issue = Issue.create!(
      title: "Boom",
      fingerprint: "ntfy::test",
      project: @project,
      exception_type: "RuntimeError",
      status: :open,
      first_seen: Time.current,
      last_seen: Time.current
    )
  end

  test "parse_url returns URI for a valid topic URL" do
    uri = NtfyNotifier.parse_url("https://ntfy.sh/my-topic")
    assert_equal "https", uri.scheme
    assert_equal "ntfy.sh", uri.host
    assert_equal "/my-topic", uri.path
  end

  test "parse_url accepts self-hosted with non-default port" do
    uri = NtfyNotifier.parse_url("http://ntfy.internal:8080/alerts")
    assert_equal 8080, uri.port
    assert_equal "/alerts", uri.path
  end

  test "parse_url rejects blank URL" do
    assert_raises(NtfyNotifier::InvalidUrl) { NtfyNotifier.parse_url("") }
    assert_raises(NtfyNotifier::InvalidUrl) { NtfyNotifier.parse_url(nil) }
  end

  test "parse_url rejects bad scheme" do
    assert_raises(NtfyNotifier::InvalidUrl) do
      NtfyNotifier.parse_url("ftp://ntfy.sh/topic")
    end
  end

  test "parse_url rejects missing topic path" do
    assert_raises(NtfyNotifier::InvalidUrl) do
      NtfyNotifier.parse_url("https://ntfy.sh/")
    end
    assert_raises(NtfyNotifier::InvalidUrl) do
      NtfyNotifier.parse_url("https://ntfy.sh")
    end
  end

  test "outbound_request builds new-issue request with title, tags, body" do
    setting = build_setting(ntfy_url: "https://ntfy.sh/splat-test", ntfy_priority: "high")

    req = NtfyNotifier.outbound_request(@issue, "new_issue", setting: setting)

    assert_equal "https://ntfy.sh/splat-test", req[:url]
    assert_equal "[Splat] New Issue: Boom", req[:headers]["Title"]
    assert_equal "high", req[:headers]["Priority"]
    assert_includes req[:headers]["Tags"], "boom"
    assert_includes req[:body], "Boom"
    assert_includes req[:body], @project.name
    refute req[:headers].key?("Authorization")
  end

  test "outbound_request sets Authorization Bearer when token configured" do
    setting = build_setting(ntfy_url: "https://ntfy.sh/splat-test", ntfy_token: "secret-token")

    req = NtfyNotifier.outbound_request(@issue, "issue_reopened", setting: setting)

    assert_equal "Bearer secret-token", req[:headers]["Authorization"]
    assert_equal "[Splat] Issue Reopened: Boom", req[:headers]["Title"]
  end

  test "outbound_request builds burst variant with rate in body" do
    @issue.update!(last_burst_rate: 1500)
    setting = build_setting(ntfy_url: "https://ntfy.sh/splat-test")

    req = NtfyNotifier.outbound_request(@issue, "issue_burst", setting: setting)

    assert_equal "[Splat] Issue Burst: Boom", req[:headers]["Title"]
    assert_includes req[:body], "1500 events/hr"
  end

  # Ruby's error_highlight appends the offending line and a caret row to the
  # exception message, and an HTTP header can't carry a line break.
  HIGHLIGHTED = "undefined local variable or method 'job' for main\n\n        job.perform\n        ^^^"

  test "outbound_request titles an error_highlight issue by its message line" do
    @issue.update!(title: HIGHLIGHTED)
    setting = build_setting(ntfy_url: "https://ntfy.sh/splat-test")

    req = NtfyNotifier.outbound_request(@issue, "new_issue", setting: setting)

    assert_equal "[Splat] New Issue: undefined local variable or method 'job' for main", req[:headers]["Title"]
  end

  # Net::HTTP refuses a header with a line break by raising ArgumentError, which
  # isn't a Faraday::Error — so it escaped deliver, failed the job, and the
  # notification never went out. A local listener stands in for ntfy.
  test "an error_highlight issue's notification reaches ntfy" do
    @issue.update!(title: HIGHLIGHTED)
    server = TCPServer.new("127.0.0.1", 0)
    received = Thread.new do
      Thread.current.report_on_exception = false
      client = server.accept
      head = []
      while (line = client.gets) && line != "\r\n"
        head << line
      end
      client.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      client.close
      head
    end
    Setting.instance.update!(ntfy_url: "http://127.0.0.1:#{server.addr[1]}/splat-test")

    NtfyNotifier.notify_new_issue(@issue)

    assert received.join(5), "ntfy never received the notification"
    assert_includes received.value.map(&:downcase), "title: [splat] new issue: undefined local variable or method 'job' for main\r\n"
  ensure
    server&.close
  end

  test "outbound_request raises InvalidUrl when ntfy_url is blank" do
    setting = build_setting(ntfy_url: nil)

    assert_raises(NtfyNotifier::InvalidUrl) do
      NtfyNotifier.outbound_request(@issue, "new_issue", setting: setting)
    end
  end

  test "notify_new_issue is a no-op when ntfy_url is blank" do
    Setting.instance.update!(ntfy_url: nil)

    assert_nothing_raised do
      NtfyNotifier.notify_new_issue(@issue)
    end
  end

  private

  def build_setting(**overrides)
    s = Setting.instance
    s.assign_attributes(overrides)
    s
  end
end
