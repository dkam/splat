# frozen_string_literal: true

module Logs
  # Bulk insert of built log rows (Ingest::LogConsumer#build_row) into their
  # day files, with their search-index entries in the same transaction.
  #
  # A row goes to the day of its log_id (see DayFiles), so a batch built across
  # midnight splits in two. `attrs_text` isn't a column: it's indexed and then
  # dropped, and the logs_fts rowid is matched to each row through its log_id,
  # since SQLite doesn't promise RETURNING rows come back in VALUES order.
  module Writer
    module_function

    def insert!(rows)
      rows.group_by { |row| DayFiles.ingest_day(row[:log_id]) }.each do |day, batch|
        DayFiles.write(day) do
          LogsRecord.transaction do
            text = batch.to_h { |row| [row[:log_id], [row[:body], row[:attrs_text]]] }
            inserted = Log.insert_all!(batch.map { |row| row.except(:attrs_text) }, returning: %w[id log_id])
            LogsRecord.with_connection do |conn|
              Fts.index(conn, inserted.rows.map { |id, log_id| [id, *text.fetch(log_id)] })
            end
          end
        end
      end
    end
  end
end
