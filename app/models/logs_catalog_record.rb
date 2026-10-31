# The logs entry in config/database.yml: since ADR 0005, a small catalog of what
# the logs day files share — the compression dictionaries and their training
# runs. Its own connection class, apart from LogsRecord, so that decoding a
# payload inside a day file's shard still finds the dictionaries.
class LogsCatalogRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: {writing: :logs, reading: :logs}
end
