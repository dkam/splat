# frozen_string_literal: true

class Api::EnvelopesController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :require_authentication

  # Each stream Settings can switch off, and the Sentry rate-limit category
  # that stands for it.
  STREAM_CATEGORIES = {store_events?: "error", store_transactions?: "transaction", store_logs?: "log_item"}.freeze

  # POST /api/:project_id/envelope/
  def create
    project = authenticate_project!
    return head :not_found unless project

    limits = rate_limits(project)
    response.headers["X-Sentry-Rate-Limits"] = limits if limits

    raw_body = Ingest::Decompression.decompress(
      Ingest::Decompression.read(request.body), request.headers["Content-Encoding"]
    )

    processor = SentryProtocol::EnvelopeProcessor.new(raw_body, project)
    processor.process
    # The envelope is lost, and a forward would go through the same tuber.
    return head :service_unavailable if processor.tuber_unreachable?

    EnvelopeForwarder.forward(raw_body, project: project, content_type: request.content_type || "application/x-sentry-envelope")

    # 200 for an envelope that couldn't be read too: sent again, it still couldn't.
    head :ok
  rescue DsnAuthenticationService::AuthenticationError => e
    Rails.logger.warn "DSN authentication failed: #{e.message}"
    head :unauthorized
  rescue Ingest::Decompression::TooLarge => e
    Rails.logger.warn "[Envelope] refused for project #{project.slug}: #{e.message}"
    head :content_too_large
  rescue Ingest::Decompression::Unreadable => e
    Rails.logger.error "[Envelope] couldn't decompress for project #{project.slug}: #{e.message}"
    head :ok
  end

  private

  # The streams switched off in Settings, as a Sentry rate limit, so SDKs stop
  # sending what Splat would throw away. They honour it on any response and
  # send again after a minute, so a stream switched back on is back within one.
  # Not for a project that forwards: its envelopes go on whole.
  def rate_limits(project)
    return if project.forwarding?

    setting = Setting.instance
    off = STREAM_CATEGORIES.filter_map { |stored, category| category unless setting.public_send(stored) }
    "60:#{off.join(";")}:organization:disabled" if off.any?
  end

  def authenticate_project!
    DsnAuthenticationService.authenticate(request, params[:project_id])
  end
end
