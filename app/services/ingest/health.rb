# frozen_string_literal: true

module Ingest
  # Tracks whether the local ingest enqueue path is healthy, so THIS instance's
  # web UI can show an "ingestion degraded" warning when Splat can't hand a job
  # to tuber — whether the job was rejected (too big) or tuber was unreachable.
  #
  # The upstream Sentry self-report (see EnvelopeProcessor) tells *another*
  # Splat/Sentry; this tells the operator looking at *this* one. State lives in
  # Solid Cache (SQLite-backed) so a failure recorded in a web process is
  # visible to every process, and it self-expires: WINDOW after the last
  # failure the warning clears on its own.
  module Health
    KEY = "ingest_enqueue_health"
    WINDOW = 10.minutes

    class << self
      # Called from the ingest path when a put fails. kind: "event" /
      # "transaction" / "log"; reason: a short human string for the header.
      def record_failure(kind:, reason:)
        prior = Rails.cache.read(KEY)
        Rails.cache.write(
          KEY,
          {
            count: (prior && prior[:count]).to_i + 1,
            kind: kind,
            reason: reason,
            at: Time.current
          },
          expires_in: WINDOW
        )
      rescue => e
        # Health tracking must never break ingestion.
        Rails.logger.warn("Ingest::Health.record_failure failed: #{e.class}: #{e.message}")
      end

      # The last failure record within WINDOW (count/kind/reason/at), or nil when
      # healthy.
      def status
        Rails.cache.read(KEY)
      rescue
        nil
      end

      def degraded?
        status.present?
      end
    end
  end
end
