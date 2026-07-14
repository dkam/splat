# frozen_string_literal: true

module Logs
  # Splits an OTLP/JSON logs payload into pieces that each fit in a single
  # tuber job. Collectors batch aggressively (a Postgres log flood produced
  # >20 MB bodies), and one oversized put raises JOB_TOO_BIG — which 500s the
  # request, so the collector retries the same too-big batch forever and the
  # logs never land. Chunks re-wrap slices of logRecords in their original
  # resource/scope envelopes, so the parser sees each chunk as a normal payload.
  module OtlpChunker
    # Per-chunk ceiling for the JSON-encoded payload. Well under the tuber
    # server's max-job-size (20mb in compose.yml) while keeping per-job batch
    # sizes sane for the logs consumer.
    MAX_BYTES = 1_000_000

    module_function

    # Returns an array of OTLP payloads whose JSON encodings each fit within
    # max_bytes. A single logRecord larger than max_bytes is emitted as its own
    # chunk anyway — the caller sees the tuber rejection and counts it dropped.
    def chunks(payload, max_bytes: MAX_BYTES)
      return [payload] if JSON.generate(payload).bytesize <= max_bytes

      out = []
      Array(payload["resourceLogs"]).each do |resource_log|
        Array(resource_log["scopeLogs"]).each do |scope_log|
          shell_bytes = JSON.generate(shell(resource_log, scope_log, [])).bytesize
          slice = []
          slice_bytes = shell_bytes
          Array(scope_log["logRecords"]).each do |record|
            record_bytes = JSON.generate(record).bytesize + 1 # +1 for the array comma
            if slice.any? && slice_bytes + record_bytes > max_bytes
              out << shell(resource_log, scope_log, slice)
              slice = []
              slice_bytes = shell_bytes
            end
            slice << record
            slice_bytes += record_bytes
          end
          out << shell(resource_log, scope_log, slice) if slice.any?
        end
      end
      out
    end

    def record_count(payload)
      Array(payload["resourceLogs"]).sum do |resource_log|
        Array(resource_log["scopeLogs"]).sum { |scope_log| Array(scope_log["logRecords"]).size }
      end
    end

    def shell(resource_log, scope_log, records)
      {
        "resourceLogs" => [
          resource_log.merge("scopeLogs" => [scope_log.merge("logRecords" => records)])
        ]
      }
    end
  end
end
