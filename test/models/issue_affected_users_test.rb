# frozen_string_literal: true

require "test_helper"

# How many users an issue has reached: distinct users across its events, the
# way Sentry's sentry:user tag counts them.
class IssueAffectedUsersTest < ActiveSupport::TestCase
  setup do
    @project = projects(:one)
    IssueFacet.reset_throttle!
  end

  def ingest(user, message: "boom")
    payload = {"message" => message, "timestamp" => Time.current.iso8601}
    payload["user"] = user if user
    Event.create_from_sentry_payload!(SecureRandom.hex(16), payload, @project)
  end

  test "an issue counts each user once, however often they hit it" do
    ingest({"id" => 42})
    ingest({"id" => 42})
    event = ingest({"id" => "7", "email" => "seven@example.com"})

    assert_equal 2, event.issue.affected_users_count
  end

  test "an issue whose events carry no user has no users" do
    event = ingest(nil)
    ingest({})

    assert_equal 0, event.issue.affected_users_count
  end

  # Sentry's order: id, username, email, ip_address. Each is told apart by its
  # kind, so a user with id 7 isn't the user named "7".
  test "a user is known by the first of id, username, email and IP address" do
    assert_equal "id:42", SentryProtocol::Payload.user_key({"user" => {"id" => 42, "email" => "a@example.com"}})
    assert_equal "username:ann", SentryProtocol::Payload.user_key({"user" => {"username" => "ann", "email" => "a@example.com"}})
    assert_equal "email:a@example.com", SentryProtocol::Payload.user_key({"user" => {"email" => "a@example.com", "ip_address" => "10.0.0.1"}})
    assert_equal "ip:10.0.0.1", SentryProtocol::Payload.user_key({"user" => {"ip_address" => "10.0.0.1"}})
  end

  # The browser SDKs send "{{auto}}" for Sentry to fill in from the request.
  # Splat doesn't, so it's no one in particular — counted, it would make every
  # browser user the same one.
  test "no user is known from a blank field, an IP address left for the server to fill in, or a user that isn't a hash" do
    assert_nil SentryProtocol::Payload.user_key({"user" => {"id" => "", "ip_address" => "{{auto}}"}})
    assert_nil SentryProtocol::Payload.user_key({"user" => "someone"})
    assert_nil SentryProtocol::Payload.user_key({})
  end

  test "users are counted for a page of issues in one query" do
    first = ingest({"id" => 1}, message: "first")
    ingest({"id" => 2}, message: "first")
    second = ingest({"id" => 1}, message: "second")
    none = ingest(nil, message: "none")

    counts = assert_queries_count(1) do
      IssueFacet.counts_by_issue([first.issue_id, second.issue_id, none.issue_id], :user)
    end

    assert_equal({first.issue_id => 2, second.issue_id => 1}, counts)
  end

  # An environment's dropdown lists environments only.
  test "users don't show up among an issue's environments or releases" do
    ingest({"id" => 42})

    assert_empty IssueFacet.values_for(@project.id, :environment)
    assert_empty IssueFacet.values_for(@project.id, :release)
  end
end
