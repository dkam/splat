# frozen_string_literal: true

class Span < TransactionsSpansRecord
  # tags + data are plain JSON columns. Use self[] so overriding readers
  # still work and NULL becomes {}.
  def tags = self[:tags] || {}
  def data = self[:data] || {}

  # Match the legacy DuckLake::Span.for_transaction signature so callers
  # don't change shape: positional transaction_id, kwargs for project + a
  # near_timestamp hint (ignored — SQLite indexes make it unnecessary, but
  # keeping it in the signature avoids touching every caller).
  def self.for_transaction(transaction_id, project_id:, near_timestamp: nil)
    where(project_id: project_id, transaction_id: transaction_id).order(:sequence)
  end

  # Duration in milliseconds (end_timestamp - timestamp). Both are stored
  # as datetimes; subtracting yields seconds.
  def duration_ms
    return nil unless end_timestamp && timestamp
    ((end_timestamp - timestamp) * 1000).round
  end
end
