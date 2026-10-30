# frozen_string_literal: true

module Logs
  # Reads across the day files: the same query on each, answers merged (ADR
  # 0005). The block builds the relation, and runs inside each file's shard —
  # ids are per file, and so are search_text's id bounds, so the relation has to
  # be built where it will run.
  #
  # `within:` is the timestamp range the relation already filters on. It
  # isn't applied here, only used to skip files whose timestamps can't overlap
  # it, so a narrow window opens one or two files rather than sixteen.
  #
  # A file retention deletes after it's listed and before it's read counts as
  # empty: its logs went with it, which is what retention was for.
  module Reader
    module_function

    # Up to `limit` logs after skipping `offset`, newest first (or oldest
    # first). Files are visited in order of their newest log (oldest), and the
    # walk stops once the page is full and the next file's newest log is older
    # than the page's last row, so a page of recent logs reads only the files
    # it takes them from.
    def list(limit:, offset: 0, within: nil, oldest_first: false, &build)
      need = offset + limit
      return [] if limit <= 0

      rows = []
      shards_by_bounds(within, oldest_first).each do |shard, (oldest, newest)|
        if rows.size >= need
          edge = rows[need - 1].timestamp
          break if oldest_first ? oldest > edge : newest < edge
        end

        found = unless_gone(shard, []) { shard.with { build.call.reorder(timestamp: oldest_first ? :asc : :desc).limit(need).to_a } }
        next if found.empty?

        # Stable, so equal timestamps keep file order and each file's own.
        rows = (rows + found).each_with_index
          .sort_by { |log, i| [oldest_first ? log.timestamp.to_r : -log.timestamp.to_r, i] }
          .first(need).map(&:first)
      end
      rows[offset, limit] || []
    end

    # Matching logs across the files.
    def count(within: nil, &build)
      shards_by_bounds(within).sum { |shard, _| unless_gone(shard, 0) { shard.with { build.call.count } } }
    end

    # A grouped count (`build` returns a relation with .group), summed across
    # files key by key.
    def group_count(within: nil, &build)
      shards_by_bounds(within).each_with_object(Hash.new(0)) do |(shard, _), totals|
        unless_gone(shard, {}) { shard.with { build.call.count } }.each { |key, n| totals[key] += n }
      end
    end

    # The log with this log_id. Its own day's file first, then the legacy
    # database, then the rest: a seek on index_logs_on_log_id in each.
    def find_by_log_id(log_id, &scope)
      return nil if log_id.blank?

      first = DayFiles.shard_for_log_id(log_id)
      rest = DayFiles.shards.reject { |s| s.name == first&.name }.partition(&:legacy?).flatten
      [first, *rest].compact.each do |shard|
        log = unless_gone(shard, nil) { shard.with { (scope ? scope.call(Log.all) : Log.all).find_by(log_id: log_id) } }
        return log if log
      end
      nil
    end

    # The log with this id in the legacy database, where an id alone still
    # names one log: links from before day files carry it. nil once the
    # legacy database has gone.
    def find_in_legacy(id, &scope)
      legacy = DayFiles.shards.find(&:legacy?) or return nil
      unless_gone(legacy, nil) { legacy.with { (scope ? scope.call(Log.all) : Log.all).find_by(id: id) } }
    end

    # A page of #list in the shape Pagy's countless paginator takes: it only
    # calls offset, limit and to_a.
    class Page
      def initialize(within: nil, oldest_first: false, offset: 0, limit: nil, &build)
        @within, @oldest_first, @offset, @limit, @build = within, oldest_first, offset, limit, build
      end

      def offset(n) = Page.new(within: @within, oldest_first: @oldest_first, offset: n, limit: @limit, &@build)

      def limit(n) = Page.new(within: @within, oldest_first: @oldest_first, offset: @offset, limit: n, &@build)

      def to_a
        Reader.list(limit: @limit, offset: @offset, within: @within, oldest_first: @oldest_first, &@build)
      end
    end

    # Files with rows, skipping any whose timestamps can't meet `within`, in
    # the order #list wants them, each with its bounds.
    def shards_by_bounds(within, oldest_first = false)
      DayFiles.shards.filter_map { |shard|
        bounds = unless_gone(shard, nil) { shard.bounds }
        next unless bounds
        next if within && !overlaps?(bounds, within)
        [shard, bounds]
      }.sort_by { |_, (oldest, newest)| oldest_first ? oldest.to_r : -newest.to_r }
    end

    # The block's answer, or `gone` when it failed because the file isn't
    # there any more. Its pool may have been dropped already (no connection
    # pool), or still be there with nothing to open (opened without CREATE).
    # A failure on a file that is still there is a real one, and raised.
    def unless_gone(shard, gone)
      yield
    rescue ActiveRecord::ActiveRecordError, SQLite3::Exception
      raise if shard.path.exist?
      gone
    end

    def overlaps?((oldest, newest), range)
      (range.begin.nil? || newest >= range.begin) &&
        (range.end.nil? || (range.exclude_end? ? oldest < range.end : oldest <= range.end))
    end
  end
end
