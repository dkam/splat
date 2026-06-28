# frozen_string_literal: true

class Span < TransactionsSpansRecord
  # tags + data are plain JSON columns. Use self[] so overriding readers
  # still work and NULL becomes {}.
  def tags = self[:tags] || {}
  def data = self[:data] || {}

  # Returns the transaction's spans as an Array of Span::Node (NOT a relation):
  # the blob is the source of truth, the legacy rows are a transitional fallback.
  # Both paths yield Span::Node so every caller (waterfall, MCP) sees one type.
  #
  # Dual-read window: prefer the SpanTree blob; fall back to legacy `spans` rows
  # for transactions ingested before the blob cutover. Once those have aged out
  # of retention (~30 days) the fallback + the legacy table can be removed.
  #
  # Signature preserved (positional transaction_id, project_id:, near_timestamp:
  # hint ignored) so callers don't change shape.
  def self.for_transaction(transaction_id, project_id:, near_timestamp: nil)
    tree_row = SpanTree.find_by(project_id: project_id, transaction_id: transaction_id)
    if tree_row
      Span::Node.from_tree(tree_row.tree)
    else
      where(project_id: project_id, transaction_id: transaction_id)
        .order(:sequence)
        .map { |span| Span::Node.from_record(span) }
    end
  end

  # Duration in milliseconds (end_timestamp - timestamp). Both are stored
  # as datetimes; subtracting yields seconds.
  def duration_ms
    return nil unless end_timestamp && timestamp
    ((end_timestamp - timestamp) * 1000).round
  end
end
