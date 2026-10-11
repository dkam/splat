# frozen_string_literal: true

require "rufus-scheduler"

module Ingest
  # Reads config/schedule.yml and pushes each entry onto its named tube on
  # the given schedule. Replaces SolidQueue's recurring.yml. If it dies, no
  # recurring jobs fire until it's restarted (the trade for not touching SQL).
  #
  # One is enough, and a second is harmless: every entry is a cron line, so
  # schedulers fire it on the same second, and carries an idp: key with a
  # cooldown, so tuber turns the second put into a no-op.
  class Scheduler
    SCHEDULE_PATH = Rails.root.join("config", "schedule.yml")

    # Seconds tuber keeps deduplicating an entry after its job is deleted. Long
    # enough to absorb a second scheduler firing the same tick a moment after a
    # fast job finished; well short of a minute, the most frequent entry's gap,
    # so it can only swallow a run if the previous one took over 30s.
    IDP_COOLDOWN = 30

    def initialize
      @rufus = Rufus::Scheduler.new
      @stop = false
    end

    def stop!
      @stop = true
      @rufus.shutdown(:kill)
    end

    def run
      register_jobs
      Rails.logger.info "[Scheduler] running with #{@rufus.jobs.size} job(s)"
      sleep 1 until @stop
    end

    private

    def register_jobs
      schedule.each do |name, entry|
        klass = entry.fetch("class")
        tube = entry.fetch("tube")
        sched = entry.fetch("schedule")
        con = entry["con"]
        idp = entry["idp"]
        args = entry["args"] || []

        register(name, klass, tube, sched, con, idp, args)
      end
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
    # reach a bury (see that job's BUSY_MESSAGE handling).
    #
    # `args:` is optional and defaults to none — it lets one job class be
    # scheduled at two cadences with different arguments (e.g. StorageStatsJob's
    # cheap hourly pass vs its deep daily one). Give each entry its own `idp:`
    # when doing that, or the two will suppress each other.
    def register(name, klass, tube, sched, con, idp, args = [])
      method, expr = sched.split(/\s+/, 2)
      payload = {class: klass, args: args}
      put_opts = {}
      put_opts[:con] = con unless con.nil?
      put_opts[:idp] = [idp, IDP_COOLDOWN] unless idp.nil?

      handler = -> {
        tags = []
        tags << "con:#{con}" if con
        tags << "idp:#{idp}" if idp
        suffix = tags.empty? ? "" : " (#{tags.join(", ")})"
        Rails.logger.info "[Scheduler] firing #{name} → #{tube}#{suffix}"
        report_put(name, tube, Tuber.put(tube, payload, **put_opts))
      }

      case method
      when "every" then @rufus.every(expr, &handler)
      when "cron" then @rufus.cron(expr, &handler)
      else raise "unknown schedule method '#{method}' for #{name}"
      end
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

    def schedule
      @schedule ||= YAML.load_file(SCHEDULE_PATH) || {}
    end
  end
end
