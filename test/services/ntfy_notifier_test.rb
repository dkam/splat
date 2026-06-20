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
