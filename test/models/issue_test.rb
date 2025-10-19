# frozen_string_literal: true

require "test_helper"

class IssueTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper
  def setup
    @project = projects(:one)
  end

  test "sends new issue email when created with notifications enabled" do
    ENV['SPLAT_EMAIL_NOTIFICATIONS'] = 'true'

    assert_emails 1 do
      Issue.create!(
        title: "New Test Issue",
        fingerprint: "new::test::fingerprint",
        project: @project,
        status: :open,
        first_seen: Time.current,
        last_seen: Time.current
      )
    end
  ensure
    ENV.delete('SPLAT_EMAIL_NOTIFICATIONS')
  end

  test "does not send new issue email in development without notifications enabled" do
    # Default development behavior
    assert_emails 0 do
      Issue.create!(
        title: "New Test Issue",
        fingerprint: "new::test::fingerprint",
        project: @project,
        status: :open,
        first_seen: Time.current,
        last_seen: Time.current
      )
    end
  end

  test "sends reopened email when issue status changes from resolved to open" do
    # Create a resolved issue
    issue = Issue.create!(
      title: "Test Issue",
      fingerprint: "test::fingerprint::reopened",
      project: @project,
      status: :resolved,
      first_seen: Time.current,
      last_seen: Time.current
    )

    # Verify it was created as resolved
    assert_equal "resolved", issue.status

    # Change to open and check email is sent
    assert_emails 1 do
      issue.update!(status: :open)
    end

    # Verify the status changed
    assert_equal "open", issue.reload.status
  end

  test "does not send reopened email when status changes from open to resolved" do
    issue = Issue.create!(
      title: "Test Issue",
      fingerprint: "test::fingerprint",
      project: @project,
      status: :open,
      first_seen: Time.current,
      last_seen: Time.current
    )

    assert_emails 0 do
      issue.update!(status: :resolved)
    end
  end

  test "does not send reopened email when status changes from ignored to open" do
    issue = Issue.create!(
      title: "Test Issue",
      fingerprint: "test::fingerprint",
      project: @project,
      status: :ignored,
      first_seen: Time.current,
      last_seen: Time.current
    )

    assert_emails 0 do
      issue.update!(status: :open)
    end
  end

  test "does not send reopened email when status stays the same" do
    issue = Issue.create!(
      title: "Test Issue",
      fingerprint: "test::fingerprint",
      project: @project,
      status: :open,
      first_seen: Time.current,
      last_seen: Time.current
    )

    assert_emails 0 do
      issue.update!(title: "Updated Title")
    end
  end

  test "correctly identifies when issues are reopened" do
    issue = Issue.create!(
      title: "Test Issue",
      fingerprint: "test::fingerprint",
      project: @project,
      status: :resolved,
      first_seen: Time.current,
      last_seen: Time.current
    )

    # Changing from resolved to open should trigger reopen email
    assert_emails 1 do
      issue.update!(status: :open)
    end
  end

  test "sends email in production environment" do
    # Mock production environment
    original_env = Rails.env
    Rails.env = ActiveSupport::StringInquirer.new("production")

    assert_emails 1 do
      Issue.create!(
        title: "Production Test Issue",
        fingerprint: "production::test::fingerprint",
        project: @project,
        status: :open,
        first_seen: Time.current,
        last_seen: Time.current
      )
    end
  ensure
    Rails.env = original_env
  end
end