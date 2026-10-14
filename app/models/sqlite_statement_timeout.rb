# frozen_string_literal: true

# A wall-clock cap on each SQLite statement, for the request paths that run a
# query someone else shaped — MCP tools, where a model picks the window and the
# filters.
#
# SQLite has no statement timeout of its own. The sqlite3 gem builds one from
# SQLite's progress handler (`Database#statement_timeout=`), and that is the
# only way to stop a query in this process: the gem holds Ruby's global lock
# for the whole of a statement, so no watchdog thread can run until it ends.
#
# Through 2.9.6 the gem's implementation is broken — it interrupts every
# statement past a couple of thousand VM steps, whatever the timeout
# (sparklemotion/sqlite3-ruby#737, fixed in 2.10.0). The Gemfile requires
# 2.10, but it's still probed once rather than trusted: on a broken gem `with`
# is a no-op instead of failing every MCP call.
module SqliteStatementTimeout
  # Every database a request might touch. A connection's timeout is its own,
  # so each pool's connection is capped separately.
  def self.records
    [ApplicationRecord, IssuesEventsRecord, TransactionsSpansRecord, LogsRecord]
  end

  def self.supported?
    return @supported if defined?(@supported)

    @supported = probe
  end

  # Runs a ~10ms query under a 10s timeout. A gem that interrupts it has the
  # bug above.
  def self.probe
    db = SQLite3::Database.new(":memory:")
    return false unless db.respond_to?(:statement_timeout=)

    db.statement_timeout = 10_000
    db.execute("WITH RECURSIVE r(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM r LIMIT 100000) SELECT count(*) FROM r")
    true
  rescue SQLite3::InterruptException
    false
  ensure
    db&.close
  end

  # Caps each statement run inside the block at `ms` milliseconds — per
  # statement, not for the block as a whole. The cap comes off again
  # afterwards: connections go back to the pool and serve the workers next,
  # where retention and the rollups legitimately run for minutes.
  def self.with(ms)
    return yield unless supported? && ms.positive?

    connections = records.map { |record| record.lease_connection.raw_connection }.uniq
    connections.each { |db| db.statement_timeout = ms }
    yield
  ensure
    # A connection Active Record reconnected mid-block has been closed, and the
    # gem doesn't check before handing the handle to SQLite.
    connections&.each { |db| db.statement_timeout = 0 unless db.closed? }
  end

  # What a statement stopped by the timeout raises, once Active Record has
  # wrapped it. Rails maps no SQLite interrupt to anything more specific.
  def self.interrupted?(error)
    error.is_a?(ActiveRecord::StatementInvalid) && error.cause.is_a?(SQLite3::InterruptException)
  end
end
