require "test_helper"

class TimelineHelperTest < ActionView::TestCase
  include TimelineHelper

  setup do
    @project = Project.create!(name: "Deploys", slug: "deploys", public_key: "deploys-key")
    @now = Time.utc(2026, 10, 18, 10, 4)
    @timeline = ProjectTimeline.new(@project, ProjectTimeline::WINDOWS.fetch("24h"), now: @now)
  end

  def deploy(version, hours_into_window)
    @project.releases.create!(version: version, first_seen_at: @timeline.range.begin + hours_into_window.hours,
      last_seen_at: @now)
  end

  # Each label is about a third of the strip wide at 953px; closer than that,
  # two of them print over each other.
  test "a deploy too close to the last labelled one keeps its line but loses its label" do
    deploy("19.12.1+aaaaaaa", 2)
    deploy("19.12.2+bbbbbbb", 3)
    deploy("19.12.3+ccccccc", 12)

    labels = timeline_deploy_labels(@timeline)
    assert_equal ["19.12.1+aaaaaaa", "19.12.3+ccccccc"], labels.map { it[:deploy].version }
    assert_equal 3, @timeline.deploys.size
  end

  # Seen at 7d: deploys half a window apart, the second near the edge, so its
  # label hung left back over the first one's.
  test "a label that would hang left over the one before it is dropped" do
    deploy("19.12.2+bbbbbbb", 12)
    deploy("19.12.3+ccccccc", 22.8)

    assert_equal ["19.12.2+bbbbbbb"], timeline_deploy_labels(@timeline).map { it[:deploy].version }
  end

  test "a label near the right edge hangs to the left of its line" do
    deploy("19.12.3+ccccccc", 2)
    deploy("19.12.4+ddddddd", 22)

    assert_equal [false, true], timeline_deploy_labels(@timeline).map { it[:hang_left] }
  end
end
