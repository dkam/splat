# frozen_string_literal: true

require "test_helper"

class IssueMailerTest < ActionMailer::TestCase
  include Rails.application.routes.url_helpers

  def setup
    @default_url_options = { host: 'localhost:3000' }
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
    ENV['SPLAT_ADMIN_EMAILS'] = 'dev1@example.com, dev2@example.com'
    email = IssueMailer.new_issue(@issue)

    assert_equal ["dev1@example.com", "dev2@example.com"], email.to
  ensure
    ENV.delete('SPLAT_ADMIN_EMAILS')
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
    ENV['SPLAT_EMAIL_FROM'] = 'custom@splat.com'
    email = IssueMailer.new_issue(@issue)

    assert_equal ["custom@splat.com"], email.from
  ensure
    ENV.delete('SPLAT_EMAIL_FROM')
  end

  test "includes issue URL in email body" do
    email = IssueMailer.new_issue(@issue)

    assert_match "http://localhost:3030/projects", email.body.encoded
  end
end