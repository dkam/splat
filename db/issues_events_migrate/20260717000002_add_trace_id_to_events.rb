# frozen_string_literal: true

# Promote contexts.trace.trace_id out of the payload blob onto the row.
#
# The Ruby SDK already sends it on every error (verified on production: 20/20
# recent events carry one), but buried in the compressed payload nothing can
# query it. Errors were the only signal not correlatable to anything else —
# `transaction_name` is the endpoint name, not a request, and it's NULL for
# background jobs entirely. This is the same promotion transactions.trace_id
# got, for the same reason, and completes events -> transactions -> logs.
#
# Cheap here in a way it wouldn't be on transactions: events is ~334k rows /
# 1.84 GB, so the column and index cost ~20 MB and the index builds in seconds.
#
# Backfill is a separate, opt-in step (`rake splat:backfill_event_trace_ids`) —
# it decodes every payload blob, so it doesn't belong in a migration blocking a
# deploy. Without it, coverage fills in over the 30-day events retention.
class AddTraceIdToEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :trace_id, :string
    # Mirrors index_transactions_on_project_id_and_trace_id: trace_id is not
    # globally unique, and every lookup is already scoped to a project.
    add_index :events, [:project_id, :trace_id]
  end
end
