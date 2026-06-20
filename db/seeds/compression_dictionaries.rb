# Seeds the v1 baseline zstd dictionary trained from production event payloads.
#
# Only events compress: stack traces, breadcrumbs, request data, and the
# modules dump are large and highly repetitive. Transactions and spans
# carry small {tags, data/measurements} blobs and live as plain JSON.
#
# Idempotent: re-running skips rows that already exist for (segment, version: 1).

class CompressionDictionarySeeder
  DICTS = [
    { segment: "events", file: "events.dict" }
  ].freeze

  # Compression::IssuesEventsDict is scoped to the issues_events DB so the
  # :binary type handles ASCII-8BIT dict bytes correctly (a raw exec_insert
  # would try to UTF-8-encode the blob).

  def self.run!
    DICTS.each do |spec|
      path = Rails.root.join("zstd_dicts", spec[:file])
      unless path.exist?
        warn "[seeds:compression_dictionaries] missing #{path} — skipping #{spec[:segment]}"
        next
      end

      if Compression::IssuesEventsDict.exists?(segment: spec[:segment], version: 1)
        Rails.logger.info "[seeds:compression_dictionaries] #{spec[:segment]} v1 already present — skipping"
        next
      end

      Compression::IssuesEventsDict.create!(
        segment:      spec[:segment],
        version:      1,
        dict:         File.binread(path),
        trained_at:   File.mtime(path),
        sample_count: nil,
        active:       true
      )

      Rails.logger.info "[seeds:compression_dictionaries] #{spec[:segment]} v1 (#{File.size(path)} bytes) seeded"
    end
  end
end

CompressionDictionarySeeder.run!
