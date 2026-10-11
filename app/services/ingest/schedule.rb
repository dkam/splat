# frozen_string_literal: true

require "fugit"

module Ingest
  # config/schedule.yml: Splat's recurring jobs, and the two ways they get run.
  #
  # Tuber 0.16 and later runs them itself: .sync hands it the whole set, and
  # from then on tuber puts each job on its tube at its time, with no process
  # of Splat's involved. The web container syncs on boot, and the ingest
  # worker puts the set back if tuber has lost it (.restore_if_lost). On an
  # older tuber, bin/scheduler (Ingest::Scheduler) puts them instead. Either way the job is the same put — the same tube,
  # body, tags, priority and TTR — so the workers can't tell the difference,
  # and the two can overlap during a changeover without running anything twice
  # (see IDP_COOLDOWN).
  #
  # Ingest::ScheduleStatus reports which of the two, if either, is running.
  module Schedule
    PATH = Rails.root.join("config", "schedule.yml")

    # The name Splat's entries are held under in tuber. A sync replaces every
    # entry under it, so it must be Splat's alone.
    OWNER = "splat"

    # Seconds tuber keeps deduplicating an entry after its job is deleted. Long
    # enough to absorb a second scheduler firing the same tick a moment after a
    # fast job finished; well short of a minute, the most frequent entry's gap,
    # so it can only swallow a run if the previous one took over 30s.
    IDP_COOLDOWN = 30

    # The tuber this Splat talks to has no recurring schedules (older than
    # 0.16), so bin/scheduler has to run them.
    class Unsupported < StandardError; end

    # One config/schedule.yml entry. +cron+ is the line without its "cron "
    # prefix, timezone included: "0 2 * * * Australia/Melbourne".
    Entry = Data.define(:name, :job_class, :args, :tube, :cron, :con, :idp) do
      # The job each run puts. +schedule+ names the entry, so the worker that
      # runs it can record the run (ScheduleRun) whoever put it.
      def body
        {class: job_class, args: args, schedule: name}
      end

      # The put tags: a concurrency key shared by every maintenance job, and an
      # idempotency key that outlives the job by IDP_COOLDOWN.
      def put_options
        {con: con, idp: idp && [idp, IDP_COOLDOWN]}.compact
      end

      def fugit
        Fugit::Cron.parse(cron) || raise(ArgumentError, "#{name}: #{cron.inspect} isn't a cron line")
      end
    end

    class << self
      def entries
        @entries ||= load(YAML.load_file(PATH) || {})
      end

      def entry(name)
        entries.find { |e| e.name == name.to_s }
      end

      # Builds entries from the YAML's hash. Every schedule must be a cron line:
      # rufus's "every 10m" counts from whenever the scheduler started, so it
      # can't be handed to tuber or fired in step by two schedulers.
      def load(yaml)
        yaml.map do |name, h|
          schedule = h.fetch("schedule")
          unless schedule.start_with?("cron ")
            raise ArgumentError, "#{name}: schedule #{schedule.inspect} must be a cron line (\"cron <5 fields> [zone]\")"
          end
          Entry.new(
            name: name, job_class: h.fetch("class"), args: h["args"] || [], tube: h.fetch("tube"),
            cron: schedule.delete_prefix("cron ").strip, con: h["con"], idp: h["idp"]
          ).tap(&:fugit)
        end.freeze
      end

      # Replaces the entries tuber holds for Splat with config/schedule.yml's.
      # An entry that's unchanged keeps its next fire; one removed from the file
      # is removed from tuber.
      #
      # @return [Tuber::Schedules::SyncResult]
      # @raise [Unsupported] tuber is older than 0.16
      # @raise [Tuber::ScheduleSyncError] tuber refused the set; it keeps
      #   running the previous one
      # @raise any of Ingest::Tuber::CONNECTION_ERRORS
      def sync(client = nil)
        own = client.nil?
        client ||= ::Tuber.new(Ingest::Tuber.address)
        client.schedules.sync(OWNER) do |s|
          entries.each do |e|
            s.add e.name, tube: e.tube, body: JSON.generate(e.body), cron: e.cron,
              pri: Ingest::Tuber::DEFAULT_PRI, ttr: Ingest::Tuber::DEFAULT_TTR, delay: 0,
              **e.put_options
          end
        end
      rescue ::Tuber::ScheduleSyncError => e
        raise Unsupported, "tuber has no recurring schedules (it's older than 0.16)" if e.status == "UNKNOWN_COMMAND"
        raise
      ensure
        client&.close if own
      end

      # Syncs only if tuber holds none of Splat's entries: a fresh tuber, or one
      # restarted without a binlog (-b), which comes back with no schedules and
      # so would fire nothing. A set tuber already holds is left alone, since
      # during a rolling deploy it may be a newer release's; the web container
      # syncs this release's on boot (bin/docker-entrypoint).
      #
      # @return [Tuber::Schedules::SyncResult, nil] nil if tuber held a set
      # @raise as .sync
      def restore_if_lost
        held = Ingest::Tuber.with_producer { |c| c.schedules.list(OWNER) }
        sync if held.empty?
      rescue ::Tuber::UnknownCommandError
        raise Unsupported, "tuber has no recurring schedules (it's older than 0.16)"
      end
    end
  end
end
