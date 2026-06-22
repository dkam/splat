class AddAttrsTextToLogs < ActiveRecord::Migration[8.1]
  def change
    # Denormalised, space-joined "key value key value" of the record's
    # attributes, written at ingest. Indexed for free-text search alongside
    # `body` by the logs_fts FTS5 table (created/maintained in
    # config/initializers/logs_fts.rb — virtual tables + triggers don't survive
    # db:schema:load, so they're ensured at boot, not here).
    add_column :logs, :attrs_text, :text
  end
end
