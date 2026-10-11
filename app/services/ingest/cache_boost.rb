# frozen_string_literal: true

module Ingest
  # Sizes one consumer's SQLite page cache to its backlog, and reports how that
  # went.
  #
  # Every connection opens with a small page cache (config/database.yml, 2 MB
  # unless SPLAT_SQLITE_CACHE_KB says otherwise). A cache fills to its limit
  # quickly and holds it, so a big one costs that much on every connection — and
  # the ingest worker holds ~17. It only pays back on a writer: a reader's cache
  # is thrown away whenever another connection writes, which in ingest is all
  # the time. So a consumer raises the cache on the one database it writes while
  # its reserves come back full, and drops it HOLD_SECONDS after the last full
  # one. Lowering cache_size frees the excess immediately.
  #
  # Measured 2026-10-11 on a 2M-row table: 2 MB vs 20 MB made no difference to
  # reads and cost ~12% on inserts at random index positions. In production the
  # transaction consumer reserves one job at a time, ~11 ms each, and is busy
  # ~11% of the time, so it's catching up after an outage that wants the speed.
  #
  # Once a window it reports jobs and time per cache size, plus process memory:
  # to the container log, and as a structured log to Splat's own Splat where
  # Sentry is configured. That's the evidence for whether the small cache costs
  # anything. A failure in here never reaches the consumer loop.
  class CacheBoost
    # A reserve at least this full means a backlog (consumers reserve up to 100).
    BOOST_BATCH = 20
    # Stay boosted this long after the last full reserve, so a backlog that
    # arrives in waves doesn't drop and rebuild the cache between them.
    HOLD_SECONDS = 60
    REPORT_SECONDS = 60

    def self.normal_kb = Integer(ENV.fetch("SPLAT_SQLITE_CACHE_KB", 2_000))

    def self.boost_kb = Integer(ENV.fetch("SPLAT_SQLITE_CACHE_BOOST_KB", 20_000))

    def initialize(name:, connection:, normal_kb: self.class.normal_kb, boost_kb: self.class.boost_kb,
      reporter: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @name = name
      @connection = connection
      @normal_kb = normal_kb
      @boost_kb = boost_kb
      @reporter = reporter || method(:report)
      @clock = clock
      @boosted = false
      @boost_until = nil
      start_window(@clock.call)
    end

    def boosted? = @boosted

    # After every reserve, empty ones included: an empty reserve is what lets
    # the hold run out when the tube goes quiet.
    def reserved(batch_size)
      now = @clock.call
      @boost_until = now + HOLD_SECONDS if batch_size >= BOOST_BATCH
      want = !@boost_until.nil? && now < @boost_until
      return if want == @boosted

      @connection.execute("PRAGMA cache_size = -#{want ? @boost_kb : @normal_kb}")
      if want
        @boosts += 1
        @boosted_since = now
      else
        @boosted_s += now - @boosted_since
      end
      @boosted = want
    rescue => e
      Rails.logger.warn "[#{@name}] cache resize failed: #{e.class}: #{e.message}"
    end

    # After every processed batch. Counted under the cache size it ran with.
    def processed(batch_size, ms)
      @jobs[@boosted] += batch_size
      @ms[@boosted] += ms
      @batches += 1
      @max_batch = batch_size if batch_size > @max_batch
    end

    def report_if_due
      now = @clock.call
      return if now - @window_start < REPORT_SECONDS

      if @batches.positive? || @boosts.positive?
        if @boosted
          @boosted_s += now - @boosted_since
          @boosted_since = now
        end
        @reporter.call(summary(now))
      end
      start_window(now)
    rescue => e
      start_window(now) if now
      Rails.logger.warn "[#{@name}] cache report failed: #{e.class}: #{e.message}"
    end

    private

    def start_window(now)
      @window_start = now
      @jobs = {false => 0, true => 0}
      @ms = {false => 0, true => 0}
      @batches = 0
      @max_batch = 0
      @boosts = 0
      @boosted_s = 0.0
    end

    def summary(now)
      {
        consumer: @name,
        window_s: (now - @window_start).round(1),
        cache_kb: @boosted ? @boost_kb : @normal_kb,
        jobs: @jobs[false] + @jobs[true],
        batches: @batches,
        max_batch: @max_batch,
        normal_jobs: @jobs[false],
        normal_ms_per_job: per_job(false),
        boosted_jobs: @jobs[true],
        boosted_ms_per_job: per_job(true),
        boosts: @boosts,
        boosted_s: @boosted_s.round(1),
        sqlite_cache_mb: sqlite_cache_mb,
        anon_mb: anon_mb
      }.compact
    end

    def per_job(boosted)
      @jobs[boosted].zero? ? nil : (@ms[boosted].to_f / @jobs[boosted]).round(2)
    end

    # SQLite's page cache across the whole process — every consumer's
    # connections, not just this one's.
    def sqlite_cache_mb
      (SQLite3.status(SQLite3::Constants::Status::PAGECACHE_OVERFLOW)[:current] / 1_048_576.0).round(1)
    rescue
      nil
    end

    # The process's own memory, not counting the file cache. Linux only.
    def anon_mb
      kb = File.read("/proc/self/smaps_rollup")[/^Anonymous:\s+(\d+)/, 1]
      kb && (kb.to_i / 1024.0).round
    rescue
      nil
    end

    def report(s)
      Rails.logger.info "[#{@name}] cache #{s.except(:consumer).map { |k, v| "#{k}=#{v}" }.join(" ")}"
      return unless defined?(Sentry) && Sentry.initialized?

      Sentry.logger.info(
        "Ingest cache: %s did %s jobs, %s ms/job at %s KB, %s ms/job boosted; sqlite cache %s MB, process %s MB",
        [s[:consumer], s[:jobs], s[:normal_ms_per_job] || "-", @normal_kb, s[:boosted_ms_per_job] || "-",
          s[:sqlite_cache_mb] || "-", s[:anon_mb] || "-"],
        **s
      )
    end
  end
end
