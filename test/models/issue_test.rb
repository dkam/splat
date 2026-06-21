# frozen_string_literal: true

require "test_helper"

class IssueTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper
  include ActiveJob::TestHelper

  def setup
    @project = projects(:one)
    # memory_store persists across tests; rolled-back issue IDs repeat, so burst
    # cache keys (burst_check/burst_alerted:<id>) would leak between tests.
    Rails.cache.clear
  end

  test "sends new issue email when created with notifications enabled" do
    ENV["SPLAT_EMAIL_NOTIFICATIONS"] = "true"

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
    ENV.delete("SPLAT_EMAIL_NOTIFICATIONS")
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

  # ---- Burst alerting (alert-only) ----

  test "maybe_alert_burst! alerts, records rate, and stays open when over threshold" do
    Setting.instance.update!(burst_threshold: 3)
    issue = create_open_issue("burst::over")
    3.times { |i| create_event(issue, i) }

    ENV["SPLAT_EMAIL_NOTIFICATIONS"] = "true"
    assert_emails 1 do
      issue.maybe_alert_burst!
    end

    issue.reload
    assert issue.open?, "alert-only must not change status"
    assert_equal 3, issue.last_burst_rate
    assert issue.bursting?
  ensure
    ENV.delete("SPLAT_EMAIL_NOTIFICATIONS")
  end

  test "maybe_alert_burst! does nothing under threshold" do
    Setting.instance.update!(burst_threshold: 100)
    issue = create_open_issue("burst::under")
    2.times { |i| create_event(issue, i) }

    ENV["SPLAT_EMAIL_NOTIFICATIONS"] = "true"
    assert_no_emails do
      issue.maybe_alert_burst!
    end

    issue.reload
    assert_nil issue.last_burst_rate
    refute issue.bursting?
  ensure
    ENV.delete("SPLAT_EMAIL_NOTIFICATIONS")
  end

  test "maybe_alert_burst! dedups alerts within the window" do
    Setting.instance.update!(burst_threshold: 3)
    issue = create_open_issue("burst::dedup")
    3.times { |i| create_event(issue, i) }

    ENV["SPLAT_EMAIL_NOTIFICATIONS"] = "true"
    assert_emails 1 do
      issue.maybe_alert_burst!
      # Bypass the 30s per-issue throttle so the second call re-checks; the
      # 1h burst_alerted dedup must still suppress a second alert.
      Rails.cache.delete("burst_check:#{issue.id}")
      issue.maybe_alert_burst!
    end
  ensure
    ENV.delete("SPLAT_EMAIL_NOTIFICATIONS")
  end

  test "maybe_alert_burst! enqueues an ntfy burst job when ntfy configured" do
    Setting.instance.update!(burst_threshold: 3, ntfy_url: "https://ntfy.sh/splat-test")
    issue = create_open_issue("burst::ntfy")
    3.times { |i| create_event(issue, i) }

    assert_enqueued_with(job: NtfyNotificationJob, args: [issue.id, "issue_burst"]) do
      issue.maybe_alert_burst!
    end
  end

  private

  def create_open_issue(fingerprint)
    Issue.create!(
      title: "Burst", fingerprint: fingerprint, project: @project,
      status: :open, first_seen: Time.current, last_seen: Time.current
    )
  end

  def create_event(issue, idx)
    issue.events.create!(
      project: @project, event_id: "evt-#{issue.id}-#{idx}",
      timestamp: Time.current
    )
  end
end
