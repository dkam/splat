# frozen_string_literal: true

require "rufus-scheduler"

module Ingest
  # Reads config/schedule.yml and pushes each entry onto its named tube on
  # the given schedule. Replaces SolidQueue's recurring.yml. One process; if
  # it dies, no recurring jobs fire until it's restarted (the trade for not
  # touching SQL).
  class Scheduler
    SCHEDULE_PATH = Rails.root.join("config", "schedule.yml")

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
        tube  = entry.fetch("tube")
        sched = entry.fetch("schedule")
        con   = entry["con"]
        idp   = entry["idp"]

        register(name, klass, tube, sched, con, idp)
      end
    end

    # `idp:` makes the put idempotent — tuber suppresses the put if a job
    # with the same key already exists in the tube (ready or reserved). For
    # a cron-driven maintenance job that occasionally runs longer than its
    # interval, this stops a queue pileup that would otherwise turn one
    # slow run into a flood after the next worker restart.
    def register(name, klass, tube, sched, con, idp)
      method, expr = sched.split(/\s+/, 2)
      payload = { class: klass, args: [] }
      put_opts = {}
      put_opts[:con] = con unless con.nil?
      put_opts[:idp] = idp unless idp.nil?

      handler = -> {
        tags = []
        tags << "con:#{con}" if con
        tags << "idp:#{idp}" if idp
        suffix = tags.empty? ? "" : " (#{tags.join(', ')})"
        Rails.logger.info "[Scheduler] firing #{name} → #{tube}#{suffix}"
        Tuber.put(tube, payload, **put_opts)
      }

      case method
      when "every" then @rufus.every(expr, &handler)
      when "cron"  then @rufus.cron(expr, &handler)
      else raise "unknown schedule method '#{method}' for #{name}"
      end
    end

    def schedule
      @schedule ||= YAML.load_file(SCHEDULE_PATH) || {}
    end
  end
end
