# frozen_string_literal: true

class ProcessTransactionJob < ApplicationJob
  queue_as :default

  def perform(transaction_id:, payload:, project:)
    transaction = nil
    ar_ms = with_span("ar.transaction.create") do
      transaction = Transaction.create_from_sentry_payload!(transaction_id, payload, project)
    end

    if transaction.release.present?
      Release.record_sighting!(project: project, version: transaction.release,
                               timestamp: transaction.timestamp, kind: :transaction)
    end

    dl_tx_ms = with_span("ducklake.transaction.mirror") { mirror_to_ducklake(transaction) }
    span_count = Array(payload["spans"]).size
    dl_sp_ms = with_span("ducklake.spans.mirror", data: { "splat.span_count" => span_count }) do
      mirror_spans_to_ducklake(transaction, payload)
    end

    Rails.logger.info(
      "Processed transaction #{transaction.id}: #{transaction.transaction_name} " \
      "req=#{transaction.duration}ms ar=#{ar_ms}ms dl_tx=#{dl_tx_ms}ms " \
      "dl_spans=#{dl_sp_ms}ms (#{span_count} spans)"
    )
  rescue => e
    # Log but don't fail - performance data is nice-to-have
    Rails.logger.error "Failed to process transaction #{transaction_id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    # Don't raise - we don't want transaction processing failures to block error processing
  end

  private

  # Time a block, also emitting a Sentry child span when a parent
  # transaction is active. with_child_span no-ops without a parent, so the
  # timing always works even when traces aren't sampled.
  def with_span(op, data: nil)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    if defined?(Sentry) && Sentry.initialized?
      Sentry.with_child_span(op: op) do |span|
        data&.each { |k, v| span&.set_data(k, v) }
        yield
      end
    else
      yield
    end
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)
  end

  # AR is the source of truth. DuckLake mirrors for analytics; failures here
  # must not break ingestion.
  def mirror_to_ducklake(transaction)
    DuckLake::Transaction.insert(
      id: transaction.id,
      transaction_id: transaction.transaction_id,
      project_id: transaction.project_id,
      timestamp: transaction.timestamp,
      transaction_name: transaction.transaction_name,
      op: transaction.op,
      duration: transaction.duration,
      db_time: transaction.db_time,
      view_time: transaction.view_time,
      environment: transaction.environment,
      release: transaction.release,
      server_name: transaction.server_name,
      http_method: transaction.http_method,
      http_status: transaction.http_status,
      http_url: transaction.http_url,
      tags: transaction.tags,
      measurements: transaction.measurements,
      spans_truncated: transaction.spans_truncated,
      query_count: transaction.query_count,
      has_n_plus_one: transaction.has_n_plus_one,
      created_at: transaction.created_at,
      updated_at: transaction.updated_at
    )
  rescue => e
    Rails.logger.error "[DuckLake] transaction mirror failed (#{transaction.transaction_id}): #{e.class}: #{e.message}"
  end

  SPAN_CAP = 1000

  def mirror_spans_to_ducklake(transaction, payload)
    raw_spans = Array(payload["spans"])
    trace_ctx = payload.dig("contexts", "trace") || {}

    root_start = parse_ts(payload["start_timestamp"])
    root_end   = parse_ts(payload["timestamp"]) || transaction.timestamp
    root_id    = trace_ctx["span_id"] || SecureRandom.hex(8)
    trace_id   = trace_ctx["trace_id"] || SecureRandom.hex(16)

    children = raw_spans.sort_by { |s| s["start_timestamp"].to_f }
    if children.size > SPAN_CAP
      children = children.first(SPAN_CAP)
      transaction.update!(spans_truncated: true) if transaction.respond_to?(:spans_truncated=)
    end

    parent_depth = { root_id => 0 }
    rows = []
    rows << build_row(
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

      rows << build_row(
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

    DuckLake::Span.multi_insert(rows)
  rescue => e
    Rails.logger.error "[DuckLake] span mirror failed (#{transaction.transaction_id}): #{e.class}: #{e.message}"
  end

  def build_row(project_id:, trace_id:, transaction_id:, span_id:, parent_span_id:,
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

  def parse_ts(value)
    case value
    when Numeric then Time.at(value)
    when String  then (Time.parse(value) rescue nil)
    when Time    then value
    end
  end
end
