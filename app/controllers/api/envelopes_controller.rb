# frozen_string_literal: true

class Api::EnvelopesController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :require_authentication

  # POST /api/:project_id/envelope/
  def create
    project = authenticate_project!
    return head :not_found unless project

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

    SentryProtocol::EnvelopeProcessor.new(raw_body, project).process

    EnvelopeForwarder.forward(raw_body, project: project, content_type: request.content_type || "application/x-sentry-envelope")

    # Always return 200 OK to avoid client retries
    head :ok
  rescue DsnAuthenticationService::AuthenticationError => e
    Rails.logger.warn "DSN authentication failed: #{e.message}"
    head :unauthorized
  end

  private

  def authenticate_project!
    DsnAuthenticationService.authenticate(request, params[:project_id])
  end
end
