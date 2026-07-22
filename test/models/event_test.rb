require "test_helper"

class EventTest < ActiveSupport::TestCase
  def setup
    @project = Project.create!(name: "Test Project", slug: "test", public_key: "test-key")
  end

  test "create_from_sentry_payload! denormalises environment and release onto the issue" do
    IssueFacet.reset_throttle!
    payload = {
      "message" => "boom", "timestamp" => "2026-07-17T08:00:00Z",
      "environment" => "staging", "release" => "v1.2.3"
    }

    event = Event.create_from_sentry_payload!("evt-facets", payload, @project)

    assert_equal %w[staging], IssueFacet.values_for(@project.id, :environment)
    assert_equal %w[v1.2.3], IssueFacet.values_for(@project.id, :release)
    assert_includes Issue.seen_in_environment("staging", project_id: @project.id), event.issue
  end

  test "a second event in another environment adds to the issue's environments" do
    IssueFacet.reset_throttle!
    base = {"message" => "boom", "timestamp" => "2026-07-17T08:00:00Z"}

    first = Event.create_from_sentry_payload!("evt-prod", base.merge("environment" => "production"), @project)
    second = Event.create_from_sentry_payload!("evt-stg", base.merge("environment" => "staging"), @project)

    # Same fingerprint, so one issue spanning both environments.
    assert_equal first.issue_id, second.issue_id
    assert_equal %w[production staging], IssueFacet.values_by_issue([first.issue_id], :environment)[first.issue_id]
  end

  test "a failing facet harvest never fails ingest" do
    with_stub(IssueFacet, :harvest!, ->(**) { raise "issue_facets is on fire" }) do
      event = Event.create_from_sentry_payload!(
        "evt-harvest-boom",
        {"message" => "boom", "timestamp" => "2026-07-17T08:00:00Z", "environment" => "production"},
        @project
      )

      assert_predicate event, :persisted?
    end
  end

  test "create_from_sentry_payload! promotes trace_id out of the trace context" do
    payload = {
      "message" => "boom",
      "timestamp" => "2026-07-17T08:00:00Z",
      "contexts" => {"trace" => {"trace_id" => "b38e43a713a14305b99bb6b5e9ac5b9c", "op" => "queue.process"}}
    }

    event = Event.create_from_sentry_payload!("evt-trace", payload, @project)

    assert_equal "b38e43a713a14305b99bb6b5e9ac5b9c", event.reload.trace_id
  end

  test "trace_id is nil when the payload carries no trace context" do
    payload = {"message" => "no trace here", "timestamp" => "2026-07-17T08:00:00Z"}

    event = Event.create_from_sentry_payload!("evt-no-trace", payload, @project)

    assert_nil event.reload.trace_id
    assert_nil event.related_transaction
  end

  test "related_transaction finds the transaction the error was thrown in" do
    trace = "fe927387680d41bc90d01992aa63ab89"
    txn = Transaction.create!(
      project: @project, transaction_id: SecureRandom.uuid, timestamp: Time.current,
      transaction_name: "BooksController#show", duration: 240, trace_id: trace
    )
    event = Event.create_from_sentry_payload!(
      "evt-correlated",
      {"message" => "boom", "timestamp" => "2026-07-17T08:00:00Z",
       "contexts" => {"trace" => {"trace_id" => trace}}},
      @project
    )

    assert_equal txn, event.related_transaction
  end

  test "related_transaction does not match another project's identical trace_id" do
    trace = "24ab1e1b736f4200b6e95b5bc2899095"
    other = Project.create!(name: "Other", slug: "other", public_key: "other-key")
    Transaction.create!(
      project: other, transaction_id: SecureRandom.uuid, timestamp: Time.current,
      transaction_name: "Other#show", duration: 10, trace_id: trace
    )
    event = Event.create_from_sentry_payload!(
      "evt-cross-project",
      {"message" => "boom", "timestamp" => "2026-07-17T08:00:00Z",
       "contexts" => {"trace" => {"trace_id" => trace}}},
      @project
    )

    # trace_id is not globally unique — the lookup must stay project-scoped.
    assert_nil event.related_transaction
  end

  test "reload re-reads the payload from the blob instead of the assigned object" do
    # The decoded payload is memoized. Without reload clearing that memo, a
    # reloaded record keeps serving what was assigned pre-save — which differs
    # from what's on disk, because JSON round-tripping turns symbol keys into
    # strings. A reloaded record must agree with a freshly-found one.
    event = Event.create!(
      project: @project, event_id: "evt-reload", timestamp: Time.current,
      payload: {message: "hi", nested: {count: 1}}
    )

    event.reload
    found = Event.find_by(event_id: "evt-reload")

    assert_equal found.payload, event.payload
    assert_equal({"message" => "hi", "nested" => {"count" => 1}}, event.payload)
  end

  test "create_from_sentry_payload! creates event with basic message" do
    payload = {
      "message" => "Test error message",
      "level" => "error",
      "timestamp" => "2025-10-18T08:00:00Z",
      "platform" => "ruby",
      "sdk" => {
        "name" => "sentry.ruby",
        "version" => "5.0.0"
      }
    }

    event = Event.create_from_sentry_payload!("test-event-id", payload, @project)

    assert_equal "test-event-id", event.event_id
    assert_equal @project, event.project
    assert_equal "ruby", event.platform
    assert_equal "sentry.ruby", event.sdk_name
    assert_equal "5.0.0", event.sdk_version
    assert_not_nil event.timestamp
    assert_equal payload, event.payload
  end

  test "create_from_sentry_payload! creates event with exception details" do
    payload = {
      "exception" => {
        "values" => [
          {
            "type" => "NoMethodError",
            "value" => "undefined method 'foo' for nil",
            "stacktrace" => {
              "frames" => [
                {
                  "filename" => "app/controllers/users_controller.rb",
                  "lineno" => 42,
                  "function" => "show"
                }
              ]
            }
          }
        ]
      },
      "timestamp" => "2025-10-18T08:00:00Z",
      "platform" => "ruby"
    }

    event = Event.create_from_sentry_payload!("exception-event-id", payload, @project)

    assert_equal "NoMethodError", event.exception_type
    assert_equal "undefined method 'foo' for nil", event.exception_value
    assert_not_nil event.issue
  end

  test "create_from_sentry_payload! groups events by issue" do
    payload = {
      "exception" => {
        "values" => [
          {
            "type" => "RuntimeError",
            "value" => "Something went wrong",
            "stacktrace" => {
              "frames" => [
                {
                  "filename" => "app/models/user.rb",
                  "lineno" => 10,
                  "function" => "validate"
                }
              ]
            }
          }
        ]
      },
      "timestamp" => "2025-10-18T08:00:00Z",
      "platform" => "ruby"
    }

    event1 = Event.create_from_sentry_payload!("event-1", payload, @project)
    event2 = Event.create_from_sentry_payload!("event-2", payload, @project)

    assert_equal event1.issue, event2.issue
    assert_equal 2, event1.issue.events.count
  end

  test "create_from_sentry_payload! uses custom fingerprint if provided" do
    payload1 = {
      "message" => "Error A",
      "timestamp" => "2025-10-18T08:00:00Z",
      "platform" => "ruby",
      "fingerprint" => ["custom", "group", "1"]
    }

    payload2 = {
      "message" => "Error B",
      "timestamp" => "2025-10-18T08:00:00Z",
      "platform" => "ruby",
      "fingerprint" => ["custom", "group", "1"]
    }

    event1 = Event.create_from_sentry_payload!("event-fp-1", payload1, @project)
    event2 = Event.create_from_sentry_payload!("event-fp-2", payload2, @project)

    assert_equal event1.issue, event2.issue
    assert_equal "custom::group::1", event1.issue.fingerprint
  end

  test "create_from_sentry_payload! includes environment and release" do
    payload = {
      "message" => "Test message",
      "timestamp" => "2025-10-18T08:00:00Z",
      "platform" => "ruby",
      "environment" => "production",
      "release" => "v1.2.3",
      "server_name" => "web-1",
      "transaction" => "UsersController#show"
    }

    event = Event.create_from_sentry_payload!("env-event-id", payload, @project)

    assert_equal "production", event.environment
    assert_equal "v1.2.3", event.release
    assert_equal "web-1", event.server_name
    assert_equal "UsersController#show", event.transaction_name
  end

  test "create_from_sentry_payload! parses different timestamp formats" do
    # ISO 8601 string
    payload1 = {
      "message" => "Test",
      "timestamp" => "2025-10-18T08:00:00Z",
      "platform" => "ruby"
    }
    event1 = Event.create_from_sentry_payload!("ts-1", payload1, @project)
    assert_kind_of Time, event1.timestamp

    # Unix timestamp
    payload2 = {
      "message" => "Test",
      "timestamp" => 1729238400.0,
      "platform" => "ruby"
    }
    event2 = Event.create_from_sentry_payload!("ts-2", payload2, @project)
    assert_kind_of Time, event2.timestamp
  end

  test "create_from_sentry_payload! handles invalid timestamp gracefully" do
    payload = {
      "message" => "Test with invalid timestamp",
      "timestamp" => "invalid-timestamp",
      "platform" => "ruby"
    }

    event = Event.create_from_sentry_payload!("ts-invalid", payload, @project)

    # Should still create event with current time as fallback
    assert_not_nil event
    assert_kind_of Time, event.timestamp
    assert_in_delta Time.current, event.timestamp, 2.seconds
  end

  test "create_from_sentry_payload! handles missing timestamp" do
    payload = {
      "message" => "Test without timestamp",
      "platform" => "ruby"
    }

    event = Event.create_from_sentry_payload!("ts-missing", payload, @project)

    # Should still create event with current time as fallback
    assert_not_nil event
    assert_kind_of Time, event.timestamp
    assert_in_delta Time.current, event.timestamp, 2.seconds
  end

  test "create_from_sentry_payload! creates issue with correct title" do
    payload = {
      "exception" => {
        "values" => [
          {
            "type" => "ArgumentError",
            "value" => "wrong number of arguments (given 2, expected 1)"
          }
        ]
      },
      "timestamp" => "2025-10-18T08:00:00Z",
      "platform" => "ruby"
    }

    event = Event.create_from_sentry_payload!("title-event", payload, @project)

    assert_equal "wrong number of arguments (given 2, expected 1)", event.issue.title
    assert_equal "ArgumentError", event.issue.exception_type
  end

  test "create_from_sentry_payload! falls back to message for title if no exception" do
    payload = {
      "message" => "Something unexpected happened",
      "timestamp" => "2025-10-18T08:00:00Z",
      "platform" => "ruby"
    }

    event = Event.create_from_sentry_payload!("msg-event", payload, @project)

    assert_equal "Something unexpected happened", event.issue.title
  end

  test "create_from_sentry_payload! advances issue.last_seen to newest event timestamp" do
    base_payload = {
      "exception" => {
        "values" => [
          {"type" => "RuntimeError", "value" => "boom",
           "stacktrace" => {"frames" => [{"filename" => "a.rb", "lineno" => 1}]}}
        ]
      },
      "platform" => "ruby"
    }

    first = Event.create_from_sentry_payload!("ev-old", base_payload.merge("timestamp" => "2025-10-18T08:00:00Z"), @project)
    second = Event.create_from_sentry_payload!("ev-new", base_payload.merge("timestamp" => "2025-10-18T12:00:00Z"), @project)

    assert_equal first.issue_id, second.issue_id
    assert_in_delta second.timestamp.to_f, first.issue.reload.last_seen.to_f, 0.001
  end

  test "create_from_sentry_payload! does not regress issue.last_seen on out-of-order events" do
    base_payload = {
      "exception" => {
        "values" => [
          {"type" => "RuntimeError", "value" => "boom",
           "stacktrace" => {"frames" => [{"filename" => "a.rb", "lineno" => 1}]}}
        ]
      },
      "platform" => "ruby"
    }

    newer = Event.create_from_sentry_payload!("ev-new", base_payload.merge("timestamp" => "2025-10-18T12:00:00Z"), @project)
    Event.create_from_sentry_payload!("ev-old", base_payload.merge("timestamp" => "2025-10-18T08:00:00Z"), @project)

    assert_in_delta newer.timestamp.to_f, newer.issue.reload.last_seen.to_f, 0.001
  end
end
