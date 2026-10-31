# Base for Log. Logs live in one SQLite file per day (Logs::DayFiles), each a
# shard of this class registered at runtime. The default shard is the catalog
# (see LogsCatalogRecord), which has no logs table, so a Log query run outside
# a day file's shard fails instead of finding nothing.
class LogsRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: {writing: :logs, reading: :logs}
end
