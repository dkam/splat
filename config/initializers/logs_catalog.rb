# frozen_string_literal: true

# Copies the legacy logs database's compression dictionaries into the logs
# catalog before anything writes or decodes a log (see
# Logs::Catalog.import_legacy!). A no-op once they're there, and on an install
# that never had the legacy database.
Rails.application.config.after_initialize do
  Logs::Catalog.import_legacy!
rescue => e
  # The catalog may not exist yet (db:prepare boots the app before creating
  # it). The next boot retries, and db:seed runs the import before seeding.
  Rails.logger.warn("[logs_catalog] legacy import skipped: #{e.class}: #{e.message}")
end
