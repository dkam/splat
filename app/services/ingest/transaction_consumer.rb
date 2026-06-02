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
      outcomes      = []
      span_rows     = []
      hist_tuples   = []

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

        span_rows.concat(build_span_rows(transaction, args["payload"]))
        hist_tuples << [transaction.project_id, transaction.transaction_name,
                        transaction.timestamp, transaction.duration]
        outcomes << [job, :ok]
      rescue ActiveRecord::RecordNotUnique
        outcomes << [job, :ok]
      rescue => e
        log_exception("[#{self.class.name}] job failed", e)
        outcomes << [job, :retry]
      end

      persist_side_effects(span_rows, hist_tuples)
      outcomes.each { |job, outcome| safe_finalize(job, outcome) }
    end

    # Spans + histogram updates land in the transactions_spans DB, all in
    # one connection. If the batch is empty (every job failed), this is a no-op.
    def persist_side_effects(span_rows, hist_tuples)
      return if span_rows.empty? && hist_tuples.empty?
      TransactionsSpansRecord.connection.transaction do
        Span.insert_all!(span_rows) if span_rows.any?
        Analytics::Histogram.bump_many!(hist_tuples)
      end
    rescue => e
      log_exception("[#{self.class.name}] persist side effects failed", e)
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

    # Pre-compressed span row for Span.insert_all! — bypasses the AR
    # before_save concern, so encode here.
    def build_span_row(project_id:, trace_id:, transaction_id:, span_id:, parent_span_id:,
                       start_ts:, end_ts:, op:, status:, description:, tags:, data:, depth:, sequence:)
      dict_id = Compression::DictChooser.choose(
        db: :transactions_spans, table: "spans", project_id: project_id
      )
      blob = Compression::Codec.encode(
        { "tags" => tags, "data" => data }.to_json,
        db: :transactions_spans, dict_id: dict_id
      )
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
        payload_blob: blob,
        dict_id: dict_id,
        depth: depth.to_i,
        sequence: sequence.to_i,
        created_at: Time.current
      }
    end

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
