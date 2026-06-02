module Compression
  # Tiered chooser for the dict to use when writing a row.
  #
  # Tiers (first hit wins):
  #   1. project-specific dict, e.g. "events:project:42"
  #   2. platform-specific dict, e.g. "events:platform:python"
  #   3. table-wide seed dict, e.g. "events"  (always present after db:seed)
  #   4. plain zstd (returns nil)
  #
  # `db` selects which compression_dictionaries table to consult; `table` is
  # the data table name (events / transactions / spans) — same value the seed
  # uses for the segment key.
  class DictChooser
    class << self
      def choose(db:, table:, project_id: nil, platform: nil)
        segments = []
        segments << "#{table}:project:#{project_id}"  if project_id
        segments << "#{table}:platform:#{platform}"   if platform
        segments << table.to_s
        segments.each do |segment|
          id = DictStore.active_id(db, segment)
          return id if id
        end
        nil
      end
    end
  end
end
