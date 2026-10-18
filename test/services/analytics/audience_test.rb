require "test_helper"

class Analytics::AudienceTest < ActiveSupport::TestCase
  setup do
    @project = projects(:one)
  end

  test "counts each dimension's values, most common first, and the events that didn't say" do
    event(ip: "198.51.100.7")
    event(ip: "198.51.100.7")
    event(ip: "203.0.113.1")
    event(ip: nil)

    audience = Analytics::Audience.new(@project.events)
    ip = audience.dimensions.find { it.key == :ip }

    assert_equal [["198.51.100.7", 2], ["203.0.113.1", 1]], ip.top
    assert_equal 2, ip.distinct
    assert_equal 1, ip.missing
    assert_equal 4, audience.read
  end

  test "reads only the newest events when there are more than the sample" do
    event(ip: "203.0.113.1", at: 2.minutes.ago)
    2.times { event(ip: "198.51.100.7", at: 1.minute.ago) }

    audience = Analytics::Audience.new(@project.events, sample: 2)
    ip = audience.dimensions.find { it.key == :ip }

    assert_equal [["198.51.100.7", 2]], ip.top
    assert_equal 2, audience.read
  end

  private

  def event(ip:, at: Time.current)
    request = ip ? {"headers" => {"X-Real-Ip" => ip}} : nil
    payload = {"message" => "Boom", "timestamp" => at.utc.iso8601, "request" => request}.compact
    Event.create_from_sentry_payload!(SecureRandom.hex(16), payload, @project)
  end
end
