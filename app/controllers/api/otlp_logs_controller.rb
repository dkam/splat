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
    Ingest::Tuber.put(
      Ingest::Tuber::LOGS_TUBE,
      {format: "otlp", payload: payload, project_id: project.id}
    )

    # OTLP success response shape (empty partialSuccess = all accepted).
    render json: {partialSuccess: {}}, status: :ok
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
end
