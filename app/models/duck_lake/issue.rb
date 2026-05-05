# frozen_string_literal: true

module DuckLake
  # Issues are mutable in AR (count + last_seen update on every event,
  # status changes on resolve/reopen/ignore). DuckLake stores append-only
  # snapshots; readers should pick the latest by (id, updated_at) when they
  # care about current state. For pure analytics (e.g. issues seen per day,
  # exception_type frequency) duplicates don't matter.
  class Issue < ApplicationDucklakeRecord
    self.table_name = "issues"
  end
end
