# frozen_string_literal: true

module Ingest
  # Stage 1 transactions: drain the transactions tube, run AR
  # create_from_sentry_payload! per row, then push hydrated transaction +
  # span rows downstream as one packed body per tube per batch.
  class TransactionConsumer < TubeConsumer
    def initialize(batch_size: DEFAULT_BATCH_SIZE)
      super(tube: Tuber::TRANSACTIONS_TUBE, batch_size: batch_size)
    end

    private

    def process_batch(jobs)
      transactions = []
      span_rows = []
      outcomes = []

      jobs.each do |job|
        args = JSON.parse(job.body)
        project = project_for(args["project_id"])
        unless project
          Rails.logger.warn "[#{self.class.name}] dropping job for missing project_id=#{args["project_id"]}"
          outcomes << [job, :ok]
          next
        end

        transaction = Transaction.create_from_sentry_payload!(args["transaction_id"], args["payload"], project)
        if transaction.release.present?
          Release.record_sighting!(project: project, version: transaction.release,
                                   timestamp: transaction.timestamp, kind: :transaction)
        end

        transactions << transaction
        span_rows.concat(build_span_rows(transaction, args["payload"]))
        outcomes << [job, :ok]
      rescue ActiveRecord::RecordNotUnique
        outcomes << [job, :ok]
      rescue => e
        log_exception("[#{self.class.name}] job failed", e)
        outcomes << [job, :retry]
      end

      forward_to_mirror(transactions, span_rows)
      outcomes.each { |job, outcome| safe_finalize(job, outcome) }
    end

    def forward_to_mirror(transactions, span_rows)
      Tuber.put(Tuber::DUCKLAKE_TRANSACTIONS_TUBE,
                { table: "transactions", rows: transactions.map(&:to_ducklake_row) }) if transactions.any?
      Tuber.put(Tuber::DUCKLAKE_SPANS_TUBE,
                { table: "spans", rows: span_rows }) if span_rows.any?
    rescue => e
      log_exception("[#{self.class.name}] mirror forward failed", e)
    end

    def build_span_rows(transaction, payload)
      raw_spans = Array(payload["spans"])
      trace_ctx = payload.dig("contexts", "trace") || {}

      root_start = parse_ts(payload["start_timestamp"])
      root_end   = parse_ts(payload["timestamp"]) || transaction.timestamp
      root_id    = trace_ctx["span_id"] || SecureRandom.hex(8)
      trace_id   = trace_ctx["trace_id"] || SecureRandom.hex(16)

      children = raw_spans.sort_by { |s| s["start_timestamp"].to_f }
      children = children.first(Transaction::SPAN_CAP) if children.size > Transaction::SPAN_CAP

      parent_depth = { root_id => 0 }
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
        tags: tags,
        data: data,
        depth: depth.to_i,
        sequence: sequence.to_i,
        created_at: Time.current
      }
    end

    # Always return UTC. JSON-serializing a non-UTC Time produces a string
    # with offset, which DuckDB's TIMESTAMP type rejects.
    def parse_ts(value)
      t = case value
          when Numeric then Time.at(value)
          when String  then (Time.parse(value) rescue nil)
          when Time    then value
          end
      t&.utc
    end
  end
end
