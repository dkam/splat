# frozen_string_literal: true

# One compressed JSON blob per transaction holding its whole span tree. Replaces
# the per-span `spans` rows: a transaction's ~55 spans serialize to a single blob
# that zstd-compresses ~10x (repeated keys/ops + ingest-normalized SQL collapse to
# backreferences).
#
# Encode/decode go through Compression::Codec directly — NOT the CompressedJson
# concern, which routes through the events/logs-only DictChooser. With dict_id nil
# the codec uses plain zstd and never touches DictStore, so this DB needs no
# compression_dictionaries tables. The nullable dict_id column is reserved for a
# future hand-trained spans dictionary (seeded like events/logs).
class SpanTree < TransactionsSpansRecord
  DB = :transactions_spans

  # tree: { "trace_id" => ..., "spans" => [ {span hash}, ... ] } — the shape
  # produced by Ingest::TransactionConsumer#build_span_tree and decoded by
  # Span::Node.from_tree.
  def self.create_from_tree!(project_id:, transaction_id:, timestamp:, tree:, span_count:, spans_truncated:, dict_id: nil)
    create!(
      project_id: project_id,
      transaction_id: transaction_id,
      timestamp: timestamp,
      payload_blob: Compression::Codec.encode(tree.to_json, db: DB, dict_id: dict_id),
      dict_id: dict_id,
      span_count: span_count,
      spans_truncated: spans_truncated
    )
  end

  # Decoded tree hash (string keys), or nil if there's no blob. Memoized.
  def tree
    @tree ||= Compression::Codec.decode_json(payload_blob, db: DB, dict_id: dict_id)
  end
end
