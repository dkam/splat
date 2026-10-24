# frozen_string_literal: true

module Ingest
  # Request bodies for the ingest endpoints: read, then decompressed by their
  # Content-Encoding, each within Sentry's own size limits
  # (docs/reference/envelopes.md#size-limits) — nothing an SDK would send to
  # Sentry is refused, and a few kilobytes that inflate to gigabytes stop at
  # the limit instead of filling a Puma thread's memory.
  module Decompression
    GZIP_MAGIC = "\x1F\x8B".b

    MAX_SENT = 20.megabytes
    MAX_DECOMPRESSED = 100.megabytes
    CHUNK = 64.kilobytes

    class TooLarge < StandardError; end

    # A body whose encoding couldn't be undone: corrupt, or not what its
    # Content-Encoding said.
    class Unreadable < StandardError; end

    module_function

    # The body, reading no further than the limit.
    def read(io)
      body = io.read(MAX_SENT + 1) || +""
      raise TooLarge, "over #{MAX_SENT / 1.megabyte} MB as sent" if body.bytesize > MAX_SENT

      body
    end

    # Gzip, deflate (zlib), Brotli or Zstandard. With no Content-Encoding, or
    # one not listed, gzip is recognised by its magic bytes.
    def decompress(body, content_encoding = nil)
      case content_encoding.to_s.downcase
      when "deflate" then inflate(body)
      when "br" then unbrotli(body)
      when "zstd" then unzstd(body)
      else maybe_gunzip(body, content_encoding)
      end
    end

    def maybe_gunzip(body, content_encoding = nil)
      return body if body.nil? || body.empty?
      return body unless content_encoding.to_s.downcase == "gzip" || body.byteslice(0, 2) == GZIP_MAGIC

      reader = Zlib::GzipReader.new(StringIO.new(body))
      within_limit { |append| while (chunk = reader.read(CHUNK)) do append.call(chunk) end }
    rescue Zlib::Error => e
      raise Unreadable, "gzip: #{e.message}"
    end

    def inflate(body)
      zlib = Zlib::Inflate.new
      within_limit do |append|
        zlib.inflate(body) { append.call(it) }
        append.call(zlib.finish)
      end
    rescue Zlib::Error => e
      raise Unreadable, "deflate: #{e.message}"
    ensure
      zlib&.close
    end

    # Brotli 0.9.1 at least: libbrotli before 1.2.1 can write out of bounds
    # decoding a crafted stream (CVE-2026-111497). See the Gemfile.
    def unbrotli(body)
      reader = Brotli::Reader.new(StringIO.new(body))
      within_limit { |append| while (chunk = reader.read(CHUNK)) do append.call(chunk) end }
    rescue Brotli::Error => e
      raise Unreadable, "br: #{e.message}"
    end

    # Fed a slice at a time, each call filling at most one output buffer, so a
    # small frame that expands enormously is cut off at the limit.
    def unzstd(body)
      stream = Zstd::StreamingDecompress.new
      within_limit do |append|
        (0...body.bytesize).step(CHUNK) do |offset|
          input = body.byteslice(offset, CHUNK)
          until input.empty?
            output, used = stream.decompress_with_pos(input)
            break if used.zero? && output.empty?

            append.call(output)
            input = input.byteslice(used..)
          end
        end
        # Output still buffered once the input is all in.
        until (output = stream.decompress_with_pos("").first).empty?
          append.call(output)
        end
      end
    rescue RuntimeError => e # zstd-ruby raises RuntimeError for a corrupt frame
      raise Unreadable, "zstd: #{e.message}"
    end

    def within_limit
      out = +"".b
      yield ->(chunk) {
        out << chunk
        raise TooLarge, "over #{MAX_DECOMPRESSED / 1.megabyte} MB decompressed" if out.bytesize > MAX_DECOMPRESSED
      }
      out
    end
  end
end
