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
  # What a read across the logs day files raises when the block's time ran
  # out between files (see cover). A StatementInvalid, as a timed-out
  # statement's error is, so callers rescue both the same way.
  class Expired < ActiveRecord::StatementInvalid; end

  STATE = :sqlite_statement_timeout

  # Every database a request might touch. A connection's timeout is its own,
  # so each pool's connection is capped separately. The logs day files aren't
  # here: each is its own pool, capped as it's opened (see cover).
  def self.records
    [ApplicationRecord, IssuesEventsRecord, TransactionsSpansRecord, LogsCatalogRecord]
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

    state = {ms: ms, deadline: now + ms / 1000.0, connections: []}
    ActiveSupport::IsolatedExecutionState[STATE] = state
    records.each { |record| cap(state, record.lease_connection.raw_connection, ms) }
    yield
  ensure
    if state
      ActiveSupport::IsolatedExecutionState.delete(STATE)
      # A connection Active Record reconnected mid-block has been closed, and
      # the gem doesn't check before handing the handle to SQLite.
      state[:connections].each { |db| db.statement_timeout = 0 unless db.closed? }
    end
  end

  # Inside a `with` block, caps the connection `record` uses right now at
  # what's left of the block's time. Logs::DayFiles::Shard#with calls it as it
  # switches to a day file, so a read across sixteen files gets the block's
  # time between them, not that much each. Raises Expired when nothing is
  # left. Outside a block, does nothing.
  def self.cover(record)
    state = ActiveSupport::IsolatedExecutionState[STATE] or return

    left = ((state[:deadline] - now) * 1000).floor
    raise Expired, "statement timeout: #{state[:ms]}ms used up" unless left.positive?

    cap(state, record.lease_connection.raw_connection, left)
  end

  # What a statement stopped by the timeout raises, once Active Record has
  # wrapped it. Rails maps no SQLite interrupt to anything more specific.
  def self.interrupted?(error)
    error.is_a?(Expired) ||
      (error.is_a?(ActiveRecord::StatementInvalid) && error.cause.is_a?(SQLite3::InterruptException))
  end

  def self.cap(state, db, ms)
    db.statement_timeout = ms
    state[:connections] << db unless state[:connections].include?(db)
  end
  private_class_method :cap

  def self.now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  private_class_method :now
end
