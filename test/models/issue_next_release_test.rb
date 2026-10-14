require "test_helper"

# Resolve in next release: fixed in the deploy to come, so events from the
# release running now — or an older one — don't reopen the issue. One from a
# release Splat sees later does.
class IssueNextReleaseTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @project = Project.create!(name: "Releases", slug: "releases", public_key: "releases-key")
    @issue = event("19.10.0", "2026-10-01T08:00:00Z").issue
    event("19.11.0", "2026-10-05T08:00:00Z")
    Setting.instance.update!(webhook_url: "https://hooks.example/splat")
  end

  test "resolves in the release after the project's newest" do
    @issue.resolve_in_next_release!

    assert @issue.reload.resolved?
    assert_equal "19.11.0", @issue.resolved_in_release
  end

  test "an event from the release it was resolved in leaves it resolved, and quiet" do
    @issue.resolve_in_next_release!

    assert_no_enqueued_jobs(only: WebhookNotificationJob) { event("19.11.0", "2026-10-06T08:00:00Z") }
    assert @issue.reload.resolved?
    assert_equal 3, @issue.count
  end

  test "an event from an older release leaves it resolved" do
    @issue.resolve_in_next_release!

    event("19.10.0", "2026-10-06T08:00:00Z")

    assert @issue.reload.resolved?
  end

  test "an event from a newer release reopens it, and says so" do
    @issue.resolve_in_next_release!

    assert_enqueued_with(job: WebhookNotificationJob, args: [@issue.id, "issue_reopened"]) do
      event("19.12.0", "2026-10-07T08:00:00Z")
    end
    assert @issue.reload.open?
    assert_nil @issue.resolved_in_release
  end

  # Nothing to compare, so as a plain resolve.
  test "an event with no release reopens it" do
    @issue.resolve_in_next_release!

    event(nil, "2026-10-06T08:00:00Z")

    assert @issue.reload.open?
  end

  test "can't resolve in the next release of a project with none seen" do
    other = Project.create!(name: "No releases", slug: "no-releases", public_key: "no-releases-key")
    issue = Event.create_from_sentry_payload!(SecureRandom.hex(16), {"message" => "boom", "timestamp" => "2026-10-01T08:00:00Z"}, other).issue

    refute issue.next_release_resolvable?
    assert_raises(Issue::NoRelease) { issue.resolve_in_next_release! }
    assert issue.reload.open?
  end

  test "resolving or reopening by hand forgets the release" do
    @issue.resolve_in_next_release!
    @issue.open!
    assert_nil @issue.reload.resolved_in_release

    @issue.resolve_in_next_release!
    @issue.resolved!
    assert_nil @issue.reload.resolved_in_release
  end

  private

  def event(release, timestamp)
    payload = {"message" => "Price parse failed", "timestamp" => timestamp, "release" => release}.compact
    Event.create_from_sentry_payload!(SecureRandom.hex(16), payload, @project)
  end
end
