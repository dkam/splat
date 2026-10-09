# frozen_string_literal: true

require "test_helper"

class IssueMailerTest < ActionMailer::TestCase
  include Rails.application.routes.url_helpers

  def setup
    @default_url_options = {host: "localhost:3000"}
    @project = projects(:one)
    @issue = Issue.create!(
      title: "Test Error",
      fingerprint: "test::fingerprint",
      project: @project,
      status: :open,
      first_seen: Time.current,
      last_seen: Time.current
    )
  end

  test "new_issue email" do
    email = IssueMailer.new_issue(@issue)

    assert_emails 1 do
      email.deliver_now
    end

    assert_equal "[Splat] New Issue: Test Error", email.subject
    assert_equal ["admin@example.com"], email.to
    assert_equal ["splat@example.com"], email.from
    assert_match "Test Error", email.body.encoded
    assert_match @project.name, email.body.encoded
  end

  test "new_issue email uses custom admin emails" do
    ENV["SPLAT_ADMIN_EMAILS"] = "dev1@example.com, dev2@example.com"
    email = IssueMailer.new_issue(@issue)

    assert_equal ["dev1@example.com", "dev2@example.com"], email.to
  ensure
    ENV.delete("SPLAT_ADMIN_EMAILS")
  end

  test "issue_reopened email" do
    @issue.update!(status: :resolved)
    @issue.update!(status: :open)

    email = IssueMailer.issue_reopened(@issue)

    assert_emails 1 do
      email.deliver_now
    end

    assert_equal "[Splat] Issue Reopened: Test Error", email.subject
    assert_equal ["admin@example.com"], email.to
    assert_match "Issue Reopened", email.body.encoded
    assert_match @issue.count.to_s, email.body.encoded
  end

  test "custom from email address" do
    ENV["SPLAT_EMAIL_FROM"] = "custom@splat.com"
    email = IssueMailer.new_issue(@issue)

    assert_equal ["custom@splat.com"], email.from
  ensure
    ENV.delete("SPLAT_EMAIL_FROM")
  end

  # Ruby's error_highlight appends the offending line and a caret row to the
  # exception message. A subject holds one line, and an h2 collapses the
  # snippet's whitespace, so the message alone heads the email.
  HIGHLIGHTED = "undefined local variable or method 'job' for main\n\n        job.perform\n        ^^^"
  MESSAGE = "undefined local variable or method 'job' for main"

  test "an error_highlight title gives its message line, not its snippet, to the subject" do
    @issue.update!(title: HIGHLIGHTED)

    assert_equal "[Splat] New Issue: #{MESSAGE}", IssueMailer.new_issue(@issue).subject
    assert_equal "[Splat] Issue Reopened: #{MESSAGE}", IssueMailer.issue_reopened(@issue).subject
    assert_equal "[Splat] Issue burst detected: #{MESSAGE}", IssueMailer.burst_detected(@issue, 500).subject
  end

  test "an error_highlight title heads the email with its message and sets the snippet below as code" do
    @issue.update!(title: HIGHLIGHTED)

    each_email do |name, email|
      html = Nokogiri::HTML(email.html_part.body.decoded)
      assert_equal MESSAGE, html.at_css("h2").text.strip, "#{name} html heading"
      # The shared indent goes; the caret keeps its column under the code.
      assert_equal "job.perform\n^^^", html.at_css("pre")&.text, "#{name} html snippet"
      assert_includes email.text_part.body.decoded, "Issue: #{MESSAGE}\n\n    job.perform\n    ^^^\n", "#{name} text"
    end
  end

  test "a one-line title gets no snippet" do
    each_email do |name, email|
      assert_nil Nokogiri::HTML(email.html_part.body.decoded).at_css("pre"), name
      assert_match(/^Issue: Test Error\n\n\S/, email.text_part.body.decoded, name)
    end
  end

  test "includes issue URL in email body" do
    email = IssueMailer.new_issue(@issue)

    # Derive the host the same way IssueMailer does (SPLAT_HOST embeds host:port,
    # default "localhost:3000") so this passes regardless of the env — local dev
    # loads .env (localhost:3030); CI leaves it unset.
    host = ENV.fetch("SPLAT_HOST", "localhost:3000")
    assert_match "http://#{host}/projects", email.body.encoded
  end

  private

  def each_email
    {
      new_issue: IssueMailer.new_issue(@issue),
      issue_reopened: IssueMailer.issue_reopened(@issue),
      burst_detected: IssueMailer.burst_detected(@issue, 500)
    }.each { |name, email| yield name, email }
  end
end
