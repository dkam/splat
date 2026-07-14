# frozen_string_literal: true

# OTLP/HTTP logs receiver. Accepts the OpenTelemetry logs JSON encoding only
# (no protobuf — keeps Splat dependency-free). A collector (e.g. scraping
# Postgres logs) points its otlphttp exporter at POST /v1/logs and sets the
# project's public key in the Authorization header (Bearer) or ?sentry_key=.
#
# Records normalize into the same `logs` table as Sentry Logs (source "otlp").
class Api::OtlpLogsController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :require_authentication

  PROTOBUF_TYPES = ["application/x-protobuf", "application/protobuf"].freeze

  def create
    # Protobuf is the collector default but unsupported here — tell the client
    # clearly rather than silently dropping (415 makes a misconfig obvious).
    if PROTOBUF_TYPES.include?(request.content_type.to_s.split(";").first)
      return render json: {error: "OTLP protobuf not supported; configure the exporter to use JSON encoding"},
        status: :unsupported_media_type
    end

    project = authenticate_project
    return head :unauthorized unless project

    # Logs disabled: accept and discard so the collector doesn't retry.
    unless Setting.instance.store_logs?
      return render json: {partialSuccess: {}}, status: :ok
    end

    payload = JSON.parse(decompressed_body)

    # Big collector batches are split so each tuber job stays under the tube's
    # max job size (Logs::OtlpChunker). Anything still too big — a single
    # enormous logRecord — is reported as rejected in partialSuccess rather
    # than 500ing, so the collector drops it instead of retrying it forever.
    rejected = 0
    Logs::OtlpChunker.chunks(payload).each do |chunk|
      Ingest::Tuber.put(
        Ingest::Tuber::LOGS_TUBE,
        {format: "otlp", payload: chunk, project_id: project.id}
      )
    rescue Beaneater::JobTooBigError
      dropped = Logs::OtlpChunker.record_count(chunk)
      rejected += dropped
      report_undeliverable_chunk(chunk, dropped, project)
    end

    # OTLP success response shape (empty partialSuccess = all accepted).
    partial = {}
    if rejected.positive?
      partial = {rejectedLogRecords: rejected, errorMessage: "log records exceeded the ingest job size limit"}
    end
    render json: {partialSuccess: partial}, status: :ok
  rescue JSON::ParserError => e
    Rails.logger.warn "[OtlpLogs] bad JSON: #{e.message}"
    render json: {error: "invalid JSON"}, status: :bad_request
  end

  private

  # Resolve the project from its public key (Authorization: Bearer <key>,
  # X-Sentry-Auth, or ?sentry_key=). Reuses the DSN extractor; OTLP has no
  # project id in the URL, so we look up by key directly.
  def authenticate_project
    public_key = DsnAuthenticationService.extract_public_key(request)
    return nil if public_key.blank?
    Project.find_by(public_key: public_key)
  rescue DsnAuthenticationService::AuthenticationError
    nil
  end

  def decompressed_body
    Ingest::Decompression.maybe_gunzip(request.body.read, request.headers["Content-Encoding"])
  end

  # A chunk that still exceeds the tuber server's max job size is a single
  # oversized logRecord — splitting can't save it, so the data is dropped.
  # That must not be silent: report it through Splat's own Sentry DSN so it
  # lands in splat-splat as one fingerprint-stable issue (reopening on
  # recurrence, notifying via ntfy) that names the knob to turn.
  def report_undeliverable_chunk(chunk, dropped, project)
    bytes = JSON.generate(chunk).bytesize
    Rails.logger.warn "[OtlpLogs] dropped #{dropped} log record(s) (#{bytes} bytes) exceeding tuber's max job size"
    Sentry.capture_message(
      "OTLP log record dropped: #{bytes} bytes exceeds tuber's max job size. " \
        "Raise TUBER_MAX_JOB_SIZE or shrink the collector's log records.",
      level: :warning,
      fingerprint: ["otlp_logs", "job_too_big"],
      extra: {chunk_bytes: bytes, records_dropped: dropped, project: project.slug}
    )
  end
end
