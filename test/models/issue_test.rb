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

  test "maybe_alert_burst! sends spike alert without ignoring when auto_ignore disabled" do
    Rails.cache.clear
    Setting.instance.update!(auto_ignore_enabled: false, auto_ignore_threshold: 3)

    issue = Issue.create!(
      title: "Noisy",
      fingerprint: "noisy::test::fingerprint",
      project: @project,
      status: :open,
      first_seen: Time.current,
      last_seen: Time.current
    )

    3.times do |i|
      Event.create!(
        project: @project,
        issue: issue,
        event_id: "evt-#{i}-#{SecureRandom.hex(4)}",
        timestamp: 10.minutes.ago,
        payload: { "message" => "boom" }
      )
    end

    assert_emails 1 do
      issue.maybe_alert_burst!
    end

    issue.reload
    assert issue.open?, "issue should stay open when auto_ignore_enabled is false"
    assert_nil issue.auto_ignored_at
    assert_equal 3, issue.auto_ignore_rate
  end

  test "maybe_alert_burst! flips to ignored when auto_ignore_enabled" do
    Rails.cache.clear
    Setting.instance.update!(auto_ignore_enabled: true, auto_ignore_threshold: 3)

    issue = Issue.create!(
      title: "Noisy auto-ignored",
      fingerprint: "noisy::ai::fingerprint",
      project: @project,
      status: :open,
      first_seen: Time.current,
      last_seen: Time.current
    )

    3.times do |i|
      Event.create!(
        project: @project,
        issue: issue,
        event_id: "evt-#{i}-#{SecureRandom.hex(4)}",
        timestamp: 10.minutes.ago,
        payload: { "message" => "boom" }
      )
    end

    assert_emails 1 do
      issue.maybe_alert_burst!
    end

    issue.reload
    assert issue.ignored?
    assert_not_nil issue.auto_ignored_at
    assert_equal 3, issue.auto_ignore_rate
  end

  test "maybe_alert_burst! is a no-op when rate is under threshold" do
    Rails.cache.clear
    Setting.instance.update!(auto_ignore_enabled: false, auto_ignore_threshold: 100)

    issue = Issue.create!(
      title: "Calm",
      fingerprint: "calm::test::fingerprint",
      project: @project,
      status: :open,
      first_seen: Time.current,
      last_seen: Time.current
    )

    Event.create!(
      project: @project,
      issue: issue,
      event_id: "evt-#{SecureRandom.hex(4)}",
      timestamp: 5.minutes.ago,
      payload: { "message" => "calm" }
    )

    assert_emails 0 do
      issue.maybe_alert_burst!
    end
    assert issue.reload.open?
    assert_nil issue.auto_ignored_at
  end

  test "maybe_alert_burst! dedupes alerts within the dedup window" do
    Rails.cache.clear
    Setting.instance.update!(auto_ignore_enabled: false, auto_ignore_threshold: 1)

    issue = Issue.create!(
      title: "Repeated bursts",
      fingerprint: "burst::dedup::fingerprint",
      project: @project,
      status: :open,
      first_seen: Time.current,
      last_seen: Time.current
    )

    Event.create!(
      project: @project,
      issue: issue,
      event_id: "evt-#{SecureRandom.hex(4)}",
      timestamp: 5.minutes.ago,
      payload: { "message" => "boom" }
    )

    assert_emails 1 do
      issue.maybe_alert_burst!
      # Clear only the per-check throttle to force re-evaluation; the
      # per-issue dedup marker should still suppress the second alert.
      Rails.cache.delete("burst_check:#{issue.id}")
      issue.maybe_alert_burst!
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