# frozen_string_literal: true

module Logs
  # The logs catalog (LogsCatalogRecord): the compression dictionaries every
  # day file's payload_blob decodes against, and their training runs.
  module Catalog
    class TrainingRun < LogsCatalogRecord
      self.table_name = "dictionary_training_runs"
    end

    module_function

    # Copies the legacy logs database's dictionaries and training runs into the
    # catalog, under the same ids: the legacy rows' dict_id point at those ids,
    # and Compression::DictStore looks every logs dictionary up here. Without
    # them, logs written before the cutover can't be decoded, and ingest would
    # write plain zstd until a new dictionary was trained.
    #
    # Runs at boot (config/initializers/logs_catalog.rb) and before the seeds
    # add a logs dictionary, so on the cutover deploy the legacy ids land in an
    # empty catalog. Idempotent: a row already here is skipped. One that holds a
    # different dictionary under a legacy id is reported, not overwritten — the
    # catalog's own rows may already be in use.
    #
    # Returns how many dictionaries were copied.
    def import_legacy!
      path = DayFiles.legacy_path
      return 0 unless path&.file?

      legacy = SQLite3::Database.new(path.to_s, readonly: true, results_as_hash: true)
      legacy.busy_timeout = 5000
      tables = legacy.execute("SELECT name FROM sqlite_master WHERE type = 'table'").map { it["name"] }
      dicts = tables.include?("compression_dictionaries") ? legacy.execute("SELECT * FROM compression_dictionaries") : []
      runs = tables.include?("dictionary_training_runs") ? legacy.execute("SELECT * FROM dictionary_training_runs") : []
      return 0 if dicts.empty? && runs.empty?

      before = Compression::LogsDict.count
      Compression::LogsDict.insert_all(dicts.map { |row| row.merge("dict" => row["dict"].b) }) if dicts.any?
      TrainingRun.insert_all(runs) if runs.any?
      copied = Compression::LogsDict.count - before

      here = Compression::LogsDict.where(id: dicts.map { it["id"] }).pluck(:id, :segment, :version).to_h { |id, *rest| [id, rest] }
      dicts.each do |row|
        next if here[row["id"]] == [row["segment"], row["version"]]

        Rails.logger.error("[logs_catalog] legacy dictionary #{row["id"]} (#{row["segment"]} v#{row["version"]}) " \
          "not copied: the catalog holds #{here[row["id"]]&.join(" v") || "another dictionary for that segment and version"}. " \
          "Legacy logs written with it can't be decoded.")
      end
      Compression::DictStore.reset! if copied.positive?
      Rails.logger.info("[logs_catalog] copied #{copied} dictionaries from #{path}") if copied.positive?
      copied
    ensure
      legacy&.close
    end
  end
end
