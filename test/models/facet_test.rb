# frozen_string_literal: true

require "test_helper"

class FacetTest < ActiveSupport::TestCase
  setup do
    @project = projects(:one)
    Facet.where(project_id: @project.id).delete_all
    # The REFRESH_INTERVAL throttle memo is process-global; clear it so each test
    # starts from a clean slate rather than inheriting another test's sightings.
    Facet.instance_variable_set(:@recent, {})
  end

  test "harvest! records distinct values and skips blanks" do
    Facet.harvest!(project_id: @project.id, stream: :log, values: {
      environment: %w[production production staging],
      source: "otlp",
      service: [nil, ""]
    })

    assert_equal %w[production staging], Facet.values_for(@project.id, :log, :environment)
    assert_equal %w[otlp], Facet.values_for(@project.id, :log, :source)
    assert_empty Facet.values_for(@project.id, :log, :service)
  end

  test "values_for is scoped by stream and name, and sorted" do
    Facet.harvest!(project_id: @project.id, stream: :log, values: {environment: "beta"})
    Facet.harvest!(project_id: @project.id, stream: :transaction, values: {environment: "alpha"})

    assert_equal %w[beta], Facet.values_for(@project.id, :log, :environment)
    assert_equal %w[alpha], Facet.values_for(@project.id, :transaction, :environment)
    assert_empty Facet.values_for(@project.id, :log, :source)
  end

  test "harvest! is idempotent - one row per value, later sighting bumps last_seen_at" do
    Facet.harvest!(project_id: @project.id, stream: :log, values: {environment: "production"})
    row = Facet.find_by!(project_id: @project.id, stream: "log", name: "environment", value: "production")
    original = row.last_seen_at

    # Clear the memo so the second harvest isn't throttled, and advance the clock.
    Facet.instance_variable_set(:@recent, {})
    later = original + 1.hour
    Facet.harvest!(project_id: @project.id, stream: :log, values: {environment: "production"}, seen_at: later)

    assert_equal 1, Facet.where(project_id: @project.id, stream: "log", name: "environment", value: "production").count
    assert_in_delta later.to_f, row.reload.last_seen_at.to_f, 1.0
  end

  test "throttle skips re-upsert within REFRESH_INTERVAL" do
    t0 = Time.current
    Facet.harvest!(project_id: @project.id, stream: :log, values: {environment: "production"}, seen_at: t0)
    row = Facet.find_by!(project_id: @project.id, stream: "log", name: "environment", value: "production")
    first_seen = row.last_seen_at

    # Same value, still inside the window (memo intact) — should be throttled out,
    # leaving last_seen_at untouched.
    Facet.harvest!(project_id: @project.id, stream: :log, values: {environment: "production"}, seen_at: t0 + 1.minute)

    assert_in_delta first_seen.to_f, row.reload.last_seen_at.to_f, 1.0
  end
end
