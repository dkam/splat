# frozen_string_literal: true

module Ingest
  # Drains splat.logs. Each job body is a *batch* — one Sentry "log" envelope
  # item (or one OTLP request) carries many records — so we parse to normalized
  # records, encode each payload (insert_all! bypasses the CompressedJson
  # before_save hook, exactly like the span path), and bulk-insert per job.
  #
  # Per-job insert keeps idempotency simple: a failed encode/insert retries only
  # that job. logs has no unique index, so a rare beanstalkd redelivery may dup
  # a batch — acceptable for high-volume logs.
  class LogConsumer < TubeConsumer
    DB = :logs
    TABLE = "logs"

    def initialize(batch_size: DEFAULT_BATCH_SIZE)
      super(tube: Tuber::LOGS_TUBE, batch_size: batch_size)
    end

    private

    def process_batch(jobs)
      outcomes = jobs.map do |job|
        args = JSON.parse(job.body)
        project = project_for(args["project_id"])
        unless project
          Rails.logger.warn "[#{self.class.name}] dropping job for missing project_id=#{args["project_id"]}"
          next [job, :ok]
        end

        records = parse(args["format"], args["payload"])
        rows = records.map { |rec| build_row(project, rec) }
        Log.insert_all!(rows) if rows.any?
        [job, :ok]
      rescue => e
        log_exception("[#{self.class.name}] job failed", e)
        [job, :retry]
      end

      outcomes.each { |job, outcome| safe_finalize(job, outcome) }
    end

    def parse(format, payload)
      case format
      when "otlp" then Logs::OtlpLogParser.parse(payload)
      else Logs::SentryLogParser.parse(payload)
      end
    end

    def build_row(project, rec)
      now = Time.current
      dict_id = Compression::DictChooser.choose(
        db: DB, table: TABLE, project_id: project.id, platform: rec[:source]
      )

      {
        project_id: project.id,
        log_id: SecureRandom.uuid_v7,
        timestamp: rec[:timestamp] || now,
        level: rec[:level],
        severity_number: rec[:severity_number],
        body: rec[:body],
        logger_name: rec[:logger_name],
        trace_id: rec[:trace_id],
        span_id: rec[:span_id],
        environment: rec[:environment],
        release: rec[:release],
        server_name: rec[:server_name],
        source: rec[:source],
        payload_blob: Compression::Codec.encode(rec[:payload].to_json, db: DB, dict_id: dict_id),
        dict_id: dict_id,
        created_at: now,
        updated_at: now
      }
    end
  end
end
