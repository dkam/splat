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

    raw_body = request.body.read

    # Decompress based on Content-Encoding header
    content_encoding = request.headers["Content-Encoding"]&.downcase

    case content_encoding
    when "deflate"
      raw_body = Zlib::Inflate.inflate(raw_body)
    when "br"
      # Brotli compression
      begin
        require "brotli"
        raw_body = Brotli.inflate(raw_body)
      rescue LoadError
        Rails.logger.error "Brotli gem not available for decompression"
        head :ok
        return
      rescue => e
        Rails.logger.error "Brotli decompression failed: #{e.message}"
        head :ok
        return
      end
    when "zstd"
      # Zstandard compression
      begin
        require "zstd"
        raw_body = Zstd.decompress(raw_body)
      rescue LoadError
        Rails.logger.error "Zstd gem not available for decompression"
        head :ok
        return
      rescue => e
        Rails.logger.error "Zstd decompression failed: #{e.message}"
        head :ok
        return
      end
    else
      # Explicit gzip, or auto-detect gzip by magic bytes when no (or an
      # unrecognized) Content-Encoding header is set.
      raw_body = Ingest::Decompression.maybe_gunzip(raw_body, content_encoding)
    end

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
