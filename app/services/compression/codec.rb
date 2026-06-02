require "zstd-ruby"

module Compression
  # Encodes/decodes payload blobs.
  #
  # encode(json_string, db:, dict_id:) — returns the compressed bytes (BLOB).
  # decode(blob, db:, dict_id:)        — returns the original JSON string.
  #
  # dict_id nil ⇒ plain zstd (no dictionary). Otherwise the dict is loaded
  # via DictStore for the row's DB.
  class Codec
    LEVEL = 3

    class << self
      def encode(payload, db:, dict_id:)
        bytes = payload.is_a?(String) ? payload : payload.to_json
        if dict_id
          entry = DictStore.fetch(db, dict_id) or
            raise ArgumentError, "Compression::Codec.encode: dict_id #{dict_id} not found in #{db}"
          Zstd.compress(bytes, level: LEVEL, dict: entry.cdict)
        else
          Zstd.compress(bytes, level: LEVEL)
        end
      end

      def decode(blob, db:, dict_id:)
        return nil if blob.nil?
        if dict_id
          entry = DictStore.fetch(db, dict_id) or
            raise ArgumentError, "Compression::Codec.decode: dict_id #{dict_id} not found in #{db}"
          Zstd.decompress(blob, dict: entry.ddict)
        else
          Zstd.decompress(blob)
        end
      end

      # Convenience: encode + JSON-parse round-trip for tests.
      def decode_json(blob, db:, dict_id:)
        raw = decode(blob, db: db, dict_id: dict_id)
        raw.nil? ? nil : JSON.parse(raw)
      end
    end
  end
end
