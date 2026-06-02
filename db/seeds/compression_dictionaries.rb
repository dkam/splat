# Seeds the v1 baseline zstd dictionaries trained from production data.
#
# Idempotent: re-running skips rows that already exist for (segment, version: 1).
# Source files live under zstd_dicts/ in the repo root.
#
# Layout:
#   zstd_dicts/events.dict        → issues_events DB, segment: "events"
#   zstd_dicts/transactions.dict  → transactions_spans DB, segment: "transactions"
#   zstd_dicts/spans.dict         → transactions_spans DB, segment: "spans"

class CompressionDictionarySeeder
  DICTS = [
    { segment: "events",       db: :issues_events,      file: "events.dict" },
    { segment: "transactions", db: :transactions_spans, file: "transactions.dict" },
    { segment: "spans",        db: :transactions_spans, file: "spans.dict" }
  ].freeze

  # Internal AR models scoped to each DB so the :binary type handles ASCII-8BIT
  # dict bytes correctly (raw exec_insert tries to UTF-8-encode the blob).
  class IssuesEventsDict < IssuesEventsRecord
    self.table_name = "compression_dictionaries"
  end

  class TransactionsSpansDict < TransactionsSpansRecord
    self.table_name = "compression_dictionaries"
  end

  def self.run!
    DICTS.each do |spec|
      path = Rails.root.join("zstd_dicts", spec[:file])
      unless path.exist?
        warn "[seeds:compression_dictionaries] missing #{path} — skipping #{spec[:segment]}"
        next
      end

      klass = case spec[:db]
              when :issues_events      then IssuesEventsDict
              when :transactions_spans then TransactionsSpansDict
              end

      if klass.exists?(segment: spec[:segment], version: 1)
        Rails.logger.info "[seeds:compression_dictionaries] #{spec[:segment]} v1 already present — skipping"
        next
      end

      klass.create!(
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
