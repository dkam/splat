# frozen_string_literal: true

require "test_helper"

class IssueFacetTest < ActiveSupport::TestCase
  setup do
    @project = projects(:one)
    @other_project = projects(:two)
    IssueFacet.delete_all
    # The REFRESH_INTERVAL throttle memo is process-global; clear it so each test
    # starts from a clean slate rather than inheriting another test's sightings.
    IssueFacet.reset_throttle!
  end

  def issue(fingerprint, project: @project)
    Issue.create!(
      title: "Issue #{fingerprint}", fingerprint: fingerprint, project: project,
      status: :open, first_seen: Time.current, last_seen: Time.current
    )
  end

  def harvest(issue, values)
    IssueFacet.harvest!(project_id: issue.project_id, issue_id: issue.id, values: values)
  end

  test "harvest! records values and skips blanks and unknown names" do
    i = issue("a")
    harvest(i, {environment: "production", release: "", platform: "ruby"})

    assert_equal %w[production], IssueFacet.values_for(@project.id, :environment)
    assert_empty IssueFacet.values_for(@project.id, :release)
    # platform isn't in NAMES, so it's dropped rather than accumulating rows.
    assert_empty IssueFacet.where(name: "platform")
  end

  test "harvest! is idempotent - one row per pair, later sighting bumps last_seen_at" do
    i = issue("a")
    harvest(i, {environment: "production"})
    row = IssueFacet.find_by!(issue_id: i.id, name: "environment", value: "production")
    original = row.last_seen_at

    IssueFacet.reset_throttle!
    IssueFacet.harvest!(project_id: @project.id, issue_id: i.id,
      values: {environment: "production"}, seen_at: original + 1.hour)

    assert_equal 1, IssueFacet.where(issue_id: i.id, name: "environment").count
    assert_operator row.reload.last_seen_at, :>, original
  end

  test "harvest! throttles a repeated pair but not a new value" do
    i = issue("a")
    harvest(i, {environment: "production"})
    assert_equal 1, IssueFacet.where(issue_id: i.id).count

    # Same pair inside REFRESH_INTERVAL: no write. A different value is a
    # different key, so it still lands — an issue's first staging event must
    # never be throttled away.
    harvest(i, {environment: "production"})
    harvest(i, {environment: "staging"})

    assert_equal %w[production staging], IssueFacet.values_for(@project.id, :environment)
  end

  test "the throttle memo is pruned rather than growing for the life of the process" do
    # Every deploy is a new release, so a long-lived recurring issue mints a new
    # throttle key indefinitely. Once a key is older than REFRESH_INTERVAL it can
    # never suppress a write again, so retaining it is pure leak. Driven through
    # due? directly with an advancing wall clock — harvest! reads Time.current,
    # which doesn't move within a test.
    start = Time.current
    40.times { |n| IssueFacet.send(:due?, "1\trelease\tv#{n}", start + (n * 2).minutes) }

    memo = IssueFacet.instance_variable_get(:@recent)
    assert_operator memo.size, :<, 40
  end

  test "issue_ids_for scopes by project when given one, spans projects otherwise" do
    mine = issue("a")
    theirs = issue("b", project: @other_project)
    harvest(mine, {environment: "production"})
    harvest(theirs, {environment: "production"})

    scoped = IssueFacet.issue_ids_for(:environment, "production", project_id: @project.id)
    assert_equal [mine.id], scoped.map(&:issue_id)

    across = IssueFacet.issue_ids_for(:environment, "production")
    assert_equal [mine.id, theirs.id].sort, across.map(&:issue_id).sort
  end

  test "values_by_issue groups a page of issues in one query" do
    a = issue("a")
    b = issue("b")
    harvest(a, {environment: "production"})
    harvest(a, {environment: "staging"})
    harvest(b, {environment: "staging"})

    result = IssueFacet.values_by_issue([a.id, b.id], :environment)

    assert_equal %w[production staging], result[a.id]
    assert_equal %w[staging], result[b.id]
    assert_empty IssueFacet.values_by_issue([], :environment)
  end

  test "an out-of-order older event does not drag last_seen_at backwards" do
    i = issue("a")
    recent = Time.current
    IssueFacet.harvest!(project_id: @project.id, issue_id: i.id,
      values: {environment: "production"}, seen_at: recent)

    # A late delivery of an old event. Letting this win would retire a live
    # value early on the next retention pass.
    IssueFacet.reset_throttle!
    IssueFacet.harvest!(project_id: @project.id, issue_id: i.id,
      values: {environment: "production"}, seen_at: recent - 30.days)

    row = IssueFacet.find_by!(issue_id: i.id, name: "environment", value: "production")
    assert_in_delta recent, row.last_seen_at, 1.second
  end

  test "deleting an issue takes its facets with it" do
    i = issue("a")
    harvest(i, {environment: "production"})

    assert_difference -> { IssueFacet.count }, -1 do
      i.destroy!
    end
  end
end
