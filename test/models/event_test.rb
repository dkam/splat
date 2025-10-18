require "test_helper"

class EventTest < ActiveSupport::TestCase
  def setup
    @project = Project.create!(name: "Test Project", slug: "test", public_key: "test-key")
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
end
