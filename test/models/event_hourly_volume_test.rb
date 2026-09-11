require "test_helper"

# Event.hourly_volume backs the sparkline on the projects index. The whole
# point of it is that a page load must not re-scan 24 hours of events, so the
# tests here are about *what gets queried*, not only what comes back.
class EventHourlyVolumeTest < ActiveSupport::TestCase
  def setup
    @project = Project.create!(name: "Volume Project", slug: "volume", public_key: "volume-key")
    @now = Time.utc(2026, 9, 11, 14, 30)
    Rails.cache.clear
  end

  test "counts events into the hour they happened in" do
    add_events(at: @now, count: 3)              # in-progress hour
    add_events(at: @now - 1.hour, count: 5)     # settling
    add_events(at: @now - 10.hours, count: 2)   # settled

    volume = hourly_volume

    assert_equal 24, volume.size
    assert_equal 3, volume.last, "the in-progress hour is the last bucket"
    assert_equal 5, volume[-2]
    assert_equal 2, volume[-11]
    assert_equal 10, volume.sum
  end

  test "events outside the window are not counted" do
    add_events(at: @now - 30.hours, count: 7)

    assert_equal 0, hourly_volume.sum
  end

  test "a settled hour is read from the cache instead of the events table" do
    add_events(at: @now - 10.hours, count: 4)
    hourly_volume

    # Delete the rows the settled bucket was built from: if the second call
    # still reports them, it can only have come from the cache.
    Event.delete_all

    assert_equal 4, hourly_volume[-11]
  end

  test "the in-progress hour is always counted fresh" do
    hourly_volume
    add_events(at: @now, count: 6)

    assert_equal 6, hourly_volume.last
  end

  test "an event arriving late into a settling hour still shows up" do
    # Splat's own ingest queue can run hours behind, so an event's timestamp
    # can land well after its hour has closed. The hours either side of the
    # boundary stay short-lived in the cache for exactly this case.
    hourly_volume
    add_events(at: @now - 1.hour, count: 2)

    assert_equal 2, hourly_volume[-2]
  end

  test "a warm cache scans only the settling window, not the whole 24 hours" do
    add_events(at: @now - 20.hours, count: 1)
    hourly_volume

    queried = capture_timestamp_bounds { hourly_volume }

    assert_equal 1, queried.size, "expected a single grouped query on a warm cache"
    span_hours = ((queried.first[:to] - queried.first[:from]) / 3600.0).round
    assert_operator span_hours, :<=, Event::SETTLING_HOURS + 1,
      "a warm load scanned #{span_hours}h of events — the cache isn't doing its job"
  end

  test "a window shorter than the settling period still works" do
    add_events(at: @now, count: 2)
    add_events(at: @now - 1.hour, count: 1)

    assert_equal [1, 2], hourly_volume(hours: 2)
    assert_equal [2], hourly_volume(hours: 1)
  end

  private

  def hourly_volume(hours: 24)
    Event.hourly_volume(project_id: @project.id, hours: hours, ending_at: @now)
  end

  def add_events(at:, count:)
    count.times do |i|
      Event.create!(project_id: @project.id, event_id: SecureRandom.uuid_v7,
        timestamp: at - i.seconds, message: "boom", payload: {})
    end
  end

  # Pull the timestamp range out of every events query the block runs, so a
  # test can assert on how much of the table was touched. The bounds arrive as
  # binds, not inlined into the SQL, so they're read from there.
  def capture_timestamp_bounds
    seen = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next unless payload[:sql]&.include?('FROM "events"')
      # Rails hands these over lazily so unread binds cost nothing to cast.
      binds = payload[:type_casted_binds]
      binds = binds.call if binds.respond_to?(:call)
      times = Array(binds).filter_map do |bind|
        Time.parse(bind.to_s) if bind.to_s.match?(/\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/)
      end
      next if times.size < 2
      seen << {from: times.min, to: times.max}
    end
    yield
    seen
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
