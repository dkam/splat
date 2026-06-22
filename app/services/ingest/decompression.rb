# frozen_string_literal: true

module Ingest
  # Shared request-body decompression for the ingest endpoints. Gzip is the only
  # codec both the Sentry envelope and OTLP logs receivers need, so it lives here
  # rather than being re-implemented per controller.
  module Decompression
    GZIP_MAGIC = "\x1F\x8B".b

    module_function

    # Gunzip when the request says gzip (Content-Encoding) or the body starts
    # with the gzip magic bytes; otherwise return the body unchanged.
    def maybe_gunzip(body, content_encoding = nil)
      return body if body.nil? || body.empty?
      if content_encoding.to_s.downcase == "gzip" || body.byteslice(0, 2) == GZIP_MAGIC
        Zlib::GzipReader.new(StringIO.new(body)).read
      else
        body
      end
    end
  end
end
