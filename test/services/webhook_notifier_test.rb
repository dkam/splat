# frozen_string_literal: true

require "test_helper"

class WebhookNotifierTest < ActiveSupport::TestCase
  setup do
    @project = projects(:one)
    @issue = Issue.create!(
      title: "undefined method 'price' for nil",
      fingerprint: "webhook::test",
      project: @project,
      exception_type: "NoMethodError",
      status: :open,
      count: 3,
      first_seen: Time.utc(2026, 10, 14, 1),
      last_seen: Time.utc(2026, 10, 14, 2)
    )
  end

  test "posts the issue as JSON" do
    req = WebhookNotifier.outbound_request(@issue, "new_issue", setting: build_setting(webhook_url: "https://hooks.example/splat"))
    body = JSON.parse(req[:body])

    assert_equal "https://hooks.example/splat", req[:url]
    assert_equal "application/json", req[:headers]["Content-Type"]
    assert_equal "new_issue", req[:headers]["X-Splat-Event"]
    assert_equal "new_issue", body["event"]
    assert_equal({"id" => @project.id, "slug" => @project.slug, "name" => @project.name}, body["project"])
    assert_equal @issue.id, body.dig("issue", "id")
    assert_equal "undefined method 'price' for nil", body.dig("issue", "title")
    assert_equal "NoMethodError", body.dig("issue", "exception_type")
    assert_equal 3, body.dig("issue", "count")
    assert_equal "2026-10-14T01:00:00Z", body.dig("issue", "first_seen")
    assert_match %r{/projects/#{@project.slug}/issues/#{@issue.id}\z}, body.dig("issue", "url")
    refute req[:headers].key?("X-Splat-Signature")
  end

  # So the receiver can tell Splat sent it: HMAC-SHA256 of the body, as GitHub does.
  test "signs the JSON body when a secret is set" do
    req = WebhookNotifier.outbound_request(@issue, "new_issue",
      setting: build_setting(webhook_url: "https://hooks.example/splat", webhook_secret: "s3cret"))

    assert_equal "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", "s3cret", req[:body])}", req[:headers]["X-Splat-Signature"]
  end

  test "carries the rate for a burst" do
    @issue.update!(last_burst_rate: 1500)
    req = WebhookNotifier.outbound_request(@issue, "issue_burst", setting: build_setting(webhook_url: "https://hooks.example/splat"))

    assert_equal 1500, JSON.parse(req[:body]).dig("issue", "burst_rate")
  end

  test "posts a Slack message, its text escaped" do
    @issue.update!(title: "expected <Book> & got nil")
    req = WebhookNotifier.outbound_request(@issue, "issue_reopened",
      setting: build_setting(webhook_url: "https://hooks.slack.com/services/T/B/x", webhook_format: "slack"))
    text = JSON.parse(req[:body])["text"]

    assert_match(/\A\*\[Splat\] Issue reopened\* in #{@project.name}/, text)
    assert_includes text, "|expected &lt;Book&gt; &amp; got nil>"
    assert_includes text, "NoMethodError"
  end

  # Discord refuses content over 2,000 characters, and would ping @everyone if
  # an error message happened to say it.
  test "posts a Discord message, cut to Discord's limit, mentioning no one" do
    @issue.update!(title: "@everyone #{"x" * 3000}")
    req = WebhookNotifier.outbound_request(@issue, "new_issue",
      setting: build_setting(webhook_url: "https://discord.com/api/webhooks/1/x", webhook_format: "discord"))
    body = JSON.parse(req[:body])

    assert_operator body["content"].length, :<=, 2000
    assert_match(/\A\*\*\[Splat\] New issue\*\* in #{@project.name}/, body["content"])
    assert_equal({"parse" => []}, body["allowed_mentions"])
  end

  test "an error_highlight issue is named by its message line" do
    @issue.update!(title: "undefined local variable or method 'job' for main\n\n        job.perform\n        ^^^")
    req = WebhookNotifier.outbound_request(@issue, "new_issue",
      setting: build_setting(webhook_url: "https://hooks.slack.com/services/T/B/x", webhook_format: "slack"))

    assert_includes JSON.parse(req[:body])["text"], "|undefined local variable or method 'job' for main>"
  end

  # A local listener stands in for the receiver.
  test "delivers to the configured URL" do
    server = TCPServer.new("127.0.0.1", 0)
    received = Thread.new do
      Thread.current.report_on_exception = false
      client = server.accept
      head = []
      while (line = client.gets) && line != "\r\n"
        head << line
      end
      length = head.find { it.downcase.start_with?("content-length:") }.split(":").last.to_i
      body = client.read(length)
      client.write("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
      client.close
      [head, body]
    end
    Setting.instance.update!(webhook_url: "http://127.0.0.1:#{server.addr[1]}/hook", webhook_secret: "s3cret")

    WebhookNotifier.notify_new_issue(@issue)

    assert received.join(5), "the webhook never arrived"
    head, body = received.value
    assert_equal @issue.id, JSON.parse(body).dig("issue", "id")
    assert_includes head.map(&:downcase), "x-splat-signature: sha256=#{OpenSSL::HMAC.hexdigest("SHA256", "s3cret", body)}\r\n"
  ensure
    server&.close
  end

  test "does nothing with no URL set" do
    Setting.instance.update!(webhook_url: nil)

    assert_nothing_raised { WebhookNotifier.notify_new_issue(@issue) }
  end

  test "a receiver that's down is logged, not raised" do
    port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    Setting.instance.update!(webhook_url: "http://127.0.0.1:#{port}/hook")

    assert_nothing_raised { WebhookNotifier.notify_new_issue(@issue) }
  end

  private

  def build_setting(**overrides)
    Setting.instance.tap { it.assign_attributes(overrides) }
  end
end
