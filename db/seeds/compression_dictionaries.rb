# Seeds the v1 baseline zstd dictionaries trained from production payloads, so a
# fresh install gets good compression before its own DictTrainingJob has enough
# data to train (and auto-promote) a better, install-specific dict.
#
#   events → events.dict (events DB): stack traces, breadcrumbs, request data,
#            and the modules dump are large and highly repetitive.
#   logs   → logs.dict   (logs DB):   Rails-style log lines share a huge amount
#            of boilerplate ("Started GET", "Completed 200 OK in …"), so even a
#            generic dict turns ~200B lines into ~60B blobs (~3.5x measured).
#
# Transactions and spans carry small {tags, data/measurements} blobs and live as
# plain JSON, so they are not seeded.
#
# Each dict lives in the same DB as the data it compresses, so the spec names a
# model scoped to that DB (a thin AR subclass on `compression_dictionaries`).
# Going through the model — not a raw exec_insert — lets the :binary column
# handle the ASCII-8BIT dict bytes correctly (a raw insert would try to UTF-8
# encode the blob).
#
# Idempotent: re-running skips any (segment, version: 1) row that already exists.

class CompressionDictionarySeeder
  DICTS = [
    {segment: "events", file: "events.dict", model: "Compression::IssuesEventsDict"},
    {segment: "logs", file: "logs.dict", model: "Compression::LogsDict"}
  ].freeze

  def self.run!
    DICTS.each do |spec|
      path = Rails.root.join("zstd_dicts", spec[:file])
      unless path.exist?
        warn "[seeds:compression_dictionaries] missing #{path} — skipping #{spec[:segment]}"
        next
      end

      model = spec[:model].constantize

      if model.exists?(segment: spec[:segment], version: 1)
        Rails.logger.info "[seeds:compression_dictionaries] #{spec[:segment]} v1 already present — skipping"
        next
      end

      model.create!(
        segment: spec[:segment],
        version: 1,
        dict: File.binread(path),
        trained_at: File.mtime(path),
        sample_count: nil,
        active: true
      )

      Rails.logger.info "[seeds:compression_dictionaries] #{spec[:segment]} v1 (#{File.size(path)} bytes) seeded"
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished => e
      # The segment's DB/table may not be migrated yet (e.g. logs on a deploy
      # that hasn't run the logs migration). Seeding runs on every boot, so it
      # will catch up on the next deploy — don't abort the rest of the seed (or
      # the container's entrypoint) over one not-yet-ready database.
      warn "[seeds:compression_dictionaries] #{spec[:segment]} not ready (#{e.class}: #{e.message}) — skipping"
    end
  end
end

CompressionDictionarySeeder.run!
