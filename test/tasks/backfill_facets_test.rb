# frozen_string_literal: true

require "test_helper"
require "rake"

class BackfillFacetsTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("splat:backfill_facets")
    Rake::Task["splat:backfill_facets"].reenable
  end

  # The code review: logs are a file per day (ADR 0005), and the default
  # shard the task queried is the catalog, which has no logs table.
  test "seeds log facets from every day file" do
    project = projects(:one)
    [[2.days.ago, "staging"], [Time.current, "production"]].each do |at, environment|
      Log.create!(project_id: project.id, log_id: log_id_at(at), timestamp: at, level: :info, source: "sentry",
        body: "x", environment: environment, payload: {})
    end

    capture_io { Rake::Task["splat:backfill_facets"].invoke }

    assert_equal %w[production staging],
      Facet.where(project_id: project.id, stream: "log", name: "environment").order(:value).pluck(:value) & %w[production staging]
  end
end
