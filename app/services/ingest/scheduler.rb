# frozen_string_literal: true

require "rufus-scheduler"

module Ingest
  # bin/scheduler: fires config/schedule.yml on a tuber too old to (< 0.16).
  #
  # On 0.16 and later tuber fires the schedule itself — the web container
  # syncs it on boot and the ingest worker puts it back if tuber loses it — so
  # this process isn't needed there, and compose.yml only starts it under the
  # old-tuber profile. Run anyway, it checks: if tuber holds the schedule it
  # goes idle without touching it; if tuber can hold one but has none, it
  # syncs it and goes idle. On an older tuber it fires the jobs through rufus,
  # as Splat always did, until tuber is upgraded underneath it and it can hand
  # them over.
  #
  # One is enough, and a second is harmless: every entry is a cron line, so
  # schedulers fire it on the same second, and carries an idp: key with a
  # cooldown, so tuber turns the second put into a no-op. The same goes for
  # this process overlapping tuber's own scheduler during the hand-over.
  class Scheduler
    SCHEDULE_PATH = Schedule::PATH
    IDP_COOLDOWN = Schedule::IDP_COOLDOWN

    # Solid Cache key the rufus fallback refreshes every TICK while it runs,
    # so ScheduleStatus can tell "bin/scheduler runs these" from "nothing does".
    HEARTBEAT_KEY = "splat:scheduler:heartbeat"
    HEARTBEAT_TTL = 3.minutes

    TICK = 60          # seconds between heartbeats / checks for an upgraded tuber
    WAIT_FOR_TUBER = 5 # seconds between attempts while tuber is unreachable

    # :idle (tuber fires the schedule) or :rufus (this process does)
    attr_reader :mode

    def initialize
      @rufus = Rufus::Scheduler.new
      @stop = false
      @mode = nil
    end

    def stop!
      @stop = true
      @rufus.shutdown(:kill)
    end

    def run
      @mode = choose_mode
      return if @stop

      if @mode == :rufus
        register_jobs
        Rails.logger.info "[Scheduler] running #{@rufus.jobs.size} job(s) from this process"
      end

      until @stop
        tick
        TICK.times do
          break if @stop
          sleep 1
        end
      end
    end

    # What one TICK does while firing the schedule: say so, and hand it to
    # tuber if tuber has since been upgraded. Idle, nothing.
    def tick
      return unless @mode == :rufus

      Rails.cache.write(HEARTBEAT_KEY, Time.current, expires_in: HEARTBEAT_TTL)
      hand_over
    rescue => e
      Rails.logger.error "[Scheduler] tick failed: #{e.class}: #{e.message}"
    end

    # :idle if tuber runs the schedule (putting it there first if tuber holds
    # none of it), :rufus if this process must fire it. Waits while tuber is
    # unreachable rather than guessing: the answer decides whether jobs fire
    # twice-and-deduped or not at all.
    def choose_mode
      until @stop
        begin
          result = Schedule.restore_if_lost
          Rails.logger.info "[Scheduler] tuber runs the schedule#{" (synced: #{describe(result)})" if result}; " \
            "nothing for this process to do. It's only needed with a tuber older than 0.16"
          return :idle
        rescue Schedule::Unsupported => e
          Rails.logger.warn "[Scheduler] #{e.message}: firing the schedule from this process"
          return :rufus
        rescue *Tuber::CONNECTION_ERRORS => e
          Rails.logger.warn "[Scheduler] tuber unreachable (#{e.class}), retrying in #{WAIT_FOR_TUBER}s"
          sleep WAIT_FOR_TUBER
        rescue => e
          # Tuber refused the set (or config/schedule.yml is broken). Whatever
          # it held before keeps running, but it isn't this release's schedule,
          # so fire it from here as well; the idp: keys absorb the overlap.
          Rails.logger.error "[Scheduler] couldn't sync the schedule into tuber: #{e.class}: #{e.message}. " \
            "Firing it from this process instead"
          Sentry.capture_exception(e, extra: {owner: Schedule::OWNER})
          return :rufus
        end
      end
    end

    private

    # Tuber was upgraded to 0.16+ while this process fired the schedule: make
    # sure it holds the set, then stop firing. Raises Unsupported, quietly
    # dropped, while tuber is still old.
    def hand_over
      result = Schedule.restore_if_lost
      @rufus.jobs.each(&:unschedule)
      Rails.cache.delete(HEARTBEAT_KEY)
      @mode = :idle
      Rails.logger.info "[Scheduler] tuber can run the schedule now#{" (synced: #{describe(result)})" if result}; " \
        "handed it over. This process can be removed"
    rescue Schedule::Unsupported
      nil
    end

    def describe(result)
      "#{result.added} added, #{result.changed} changed, #{result.removed} removed, #{result.unchanged} unchanged"
    end

    def register_jobs
      Schedule.entries.each { |entry| register(entry) }
    end

    # `idp:` makes the put idempotent — tuber suppresses the put if a job
    # with the same key already exists in the tube. For a cron-driven
    # maintenance job that occasionally runs longer than its interval, this
    # stops a queue pileup that would otherwise turn one slow run into a flood
    # after the next worker restart.
    #
    # IMPORTANT: "already exists" includes BURIED, not just ready/reserved. A
    # buried job holds its key and suppresses every later put until someone
    # kicks or deletes it. On 2026-09-09 Analytics::HistogramRollupJob buried on
    # SQLite lock contention and the next ~70 hourly puts were dropped; it was
    # dead for three days while this logged "firing". Tuber's reply said BURIED
    # every time, and nothing read it — #report_put now does. Jobs on this tube
    # should still swallow expected, transient failures rather than let them
    # reach a bury (see that job's BUSY_MESSAGE handling). Tuber's own scheduler
    # counts the same thing as buried-streak, which the settings page shows.
    #
    # `args:` is optional and defaults to none — it lets one job class be
    # scheduled at two cadences with different arguments (e.g. StorageStatsJob's
    # cheap hourly pass vs its deep daily one). Give each entry its own `idp:`
    # when doing that, or the two will suppress each other.
    def register(entry)
      handler = -> {
        tags = entry.put_options.map { |k, v| "#{k}:#{Array(v).first}" }
        suffix = tags.empty? ? "" : " (#{tags.join(", ")})"
        Rails.logger.info "[Scheduler] firing #{entry.name} → #{entry.tube}#{suffix}"
        report_put(entry.name, entry.tube, Tuber.put(entry.tube, entry.body, **entry.put_options))
      }
      @rufus.cron(entry.cron, &handler)
    end

    # A put whose idp: key matches a job already in the tube creates nothing,
    # and tuber's reply carries that job's state. READY, RESERVED or DELAYED is
    # the key doing its job: the last run is still queued or running. DELETED is
    # the cooldown absorbing a second scheduler. BURIED is an outage: that run
    # failed out and kept the key, so this run is lost, and so is every one
    # after it until someone kicks or deletes the buried job. Reported on every
    # put rather than once, so the issue's count is the runs lost and a resolved
    # issue reopens while the job is still stuck.
    def report_put(name, tube, reply)
      state = reply.is_a?(Hash) ? reply[:state] : nil
      return if state.nil?

      if state == "BURIED"
        Rails.logger.error "[Scheduler] #{name} did not run: job #{reply[:id]} on #{tube} is buried " \
          "and holds its idp key — kick or delete it"
        Sentry.capture_message(
          "Scheduled job #{name} is not running: an earlier run is buried on #{tube}",
          level: :error,
          fingerprint: ["scheduler", "suppressed_by_buried", name],
          extra: {entry: name, tube: tube, buried_job_id: reply[:id]}
        )
      else
        Rails.logger.info "[Scheduler] #{name} skipped: job #{reply[:id]} is #{state.downcase}"
      end
    rescue => e
      Rails.logger.error "[Scheduler] couldn't report #{name}'s put: #{e.class}: #{e.message}"
    end
  end
end
