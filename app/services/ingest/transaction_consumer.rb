# frozen_string_literal: true

module Ingest
  # Drains splat.transactions: runs AR create_from_sentry_payload!, extracts
  # spans into the same DB via insert_all!, and bumps the live-hour
  # transaction_histograms counters in one batched ON CONFLICT INSERT.
  class TransactionConsumer < TubeConsumer
    def initialize(batch_size: DEFAULT_BATCH_SIZE)
      super(tube: Tuber::TRANSACTIONS_TUBE, batch_size: batch_size)
    end

    private

    def process_batch(jobs)
      outcomes = []

      jobs.each do |job|
        args = JSON.parse(job.body)
        project = project_for(args["project_id"])
        unless project
          Rails.logger.warn "[#{self.class.name}] dropping job for missing project_id=#{args["project_id"]}"
          outcomes << [job, :ok]
          next
        end

        # One TransactionsSpansRecord transaction per job: the parent row, its
        # span-tree blob, and the live-hour aggregate bumps commit together or not
        # at all. On rollback the rescue below marks the job :retry so beanstalkd
        # redelivers it. create_from_sentry_payload! is idempotent on
        # (project_id, transaction_id): a redelivery finds the existing row and
        # skips the save, leaving previously_new_record? false. The aggregate
        # bumps fire from Transaction's after_create (only on a real insert), so
        # redelivery can't double-count; we gate the span-tree write on
        # previously_new_record? too — the span_trees unique index would otherwise
        # raise on redelivery and bounce the whole job into a retry loop.
        transaction = nil
        TransactionsSpansRecord.transaction do
          transaction = Transaction.create_from_sentry_payload!(args["transaction_id"], args["payload"], project)
          if transaction.previously_new_record?
            span_rows = build_span_rows(transaction, args["payload"])
            if span_rows.any?
              SpanTree.create_from_tree!(
                project_id: transaction.project_id,
                transaction_id: transaction.transaction_id,
                timestamp: transaction.timestamp,
                tree: build_span_tree(span_rows),
                span_count: span_rows.size,
                spans_truncated: transaction.spans_truncated
              )
            end
          end
        end

        # Release lives on the primary DB, so it can't share the inner txn.
        # record_sighting! is idempotent; safe to run after the inner commit.
        if transaction&.release.present?
          Release.record_sighting!(project: project, version: transaction.release,
            timestamp: transaction.timestamp, kind: :transaction)
        end

        outcomes << [job, :ok]
      rescue ActiveRecord::RecordNotUnique
        outcomes << [job, :ok]
      rescue => e
        log_exception("[#{self.class.name}] job failed", e)
        outcomes << [job, :retry]
      end

      outcomes.each { |job, outcome| safe_finalize(job, outcome) }
    end

    def build_span_rows(transaction, payload)
      raw_spans = Array(payload["spans"])
      trace_ctx = payload.dig("contexts", "trace") || {}

      root_start = parse_ts(payload["start_timestamp"])
      root_end = parse_ts(payload["timestamp"]) || transaction.timestamp
      root_id = trace_ctx["span_id"] || SecureRandom.hex(8)
      trace_id = trace_ctx["trace_id"] || SecureRandom.hex(16)

      children = raw_spans.sort_by { |s| s["start_timestamp"].to_f }
      children = children.first(Transaction::SPAN_CAP) if children.size > Transaction::SPAN_CAP

      parent_depth = {root_id => 0}
      rows = []
      rows << build_span_row(
        project_id: transaction.project_id,
        trace_id: trace_id, transaction_id: transaction.transaction_id,
        span_id: root_id, parent_span_id: nil,
        start_ts: root_start || transaction.timestamp,
        end_ts: root_end,
        op: trace_ctx["op"] || transaction.op,
        status: trace_ctx.dig("status") || "ok",
        description: payload["transaction"],
        tags: trace_ctx["tags"], data: trace_ctx["data"],
        depth: 0, sequence: 0
      )

      children.each_with_index do |s, i|
        parent_id = s["parent_span_id"]
        depth = (parent_depth[parent_id] || 0) + 1
        parent_depth[s["span_id"]] = depth if s["span_id"]

        rows << build_span_row(
          project_id: transaction.project_id,
          trace_id: s["trace_id"] || trace_id,
          transaction_id: transaction.transaction_id,
          span_id: s["span_id"] || SecureRandom.hex(8),
          parent_span_id: parent_id,
          start_ts: parse_ts(s["start_timestamp"]) || transaction.timestamp,
          end_ts: parse_ts(s["timestamp"]) || transaction.timestamp,
          op: s["op"], status: s["status"],
          description: s["description"],
          tags: s["tags"], data: s["data"],
          depth: depth, sequence: i + 1
        )
      end

      rows
    end

    # Reshape the span rows into the compressed-blob tree: trace_id hoisted once
    # (constant per transaction), per-span fields inline. The shorter "ts"/"end_ts"
    # keys are the on-disk form decoded by Span::Node.from_tree — keep the two in
    # sync. This is the exact shape the compression spot-check measured (~10x plain
    # zstd). tags/data stay raw Hashes so to_json serializes them once here.
    def build_span_tree(span_rows)
      {
        "trace_id" => span_rows.first[:trace_id],
        "spans" => span_rows.map do |r|
          {
            "span_id" => r[:span_id], "parent_span_id" => r[:parent_span_id],
            "op" => r[:op], "status" => r[:status], "description" => r[:description],
            "ts" => r[:timestamp], "end_ts" => r[:end_timestamp],
            "depth" => r[:depth], "sequence" => r[:sequence],
            "tags" => r[:tags] || {}, "data" => r[:data] || {}
          }
        end
      }
    end

    # Row consumed by build_span_tree. tags/data are kept as raw Hashes so the
    # single tree.to_json (in SpanTree.create_from_tree!) serializes them once.
    def build_span_row(project_id:, trace_id:, transaction_id:, span_id:, parent_span_id:,
      start_ts:, end_ts:, op:, status:, description:, tags:, data:, depth:, sequence:)
      {
        project_id: project_id,
        trace_id: trace_id,
        transaction_id: transaction_id,
        span_id: span_id,
        parent_span_id: parent_span_id,
        timestamp: start_ts,
        end_timestamp: end_ts,
        op: op,
        status: status,
        description: Transaction::SqlNormalizer.normalize(description),
        tags: tags || {},
        data: data || {},
        depth: depth.to_i,
        sequence: sequence.to_i,
        created_at: Time.current
      }
    end

    def parse_ts(value)
      t = case value
      when Numeric then Time.at(value)
      when String then begin
        Time.parse(value)
      rescue
        nil
      end
      when Time then value
      end
      t&.utc
    end
  end
end
