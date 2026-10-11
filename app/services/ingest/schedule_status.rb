# frozen_string_literal: true

module Ingest
  # Is anything running config/schedule.yml? Nothing would say so otherwise:
  # the jobs that stop are retention (the disk fills), the WAL checkpoint (the
  # WAL runs away, as it did on 2026-08-17) and monitor evaluation, which is
  # what raises alerts — so it can't raise this one.
  #
  # Two views:
  # - .entries: per entry, for the settings page — what runs it (tuber,
  #   bin/scheduler, or nothing), when it last ran and will next fire, and
  #   whether it's late or stuck behind a buried job.
  # - .health: one answer for /_health, from the database alone, so Uptime
  #   Kuma catches a stopped schedule nobody is looking at.
  module ScheduleStatus
    # The entry /_health watches. It runs every minute on splat.checkins, which
    # nothing heavy shares, so it's late only when nothing is firing it or the
    # ingest worker that runs it is down — and both are outages.
    HEALTH_ENTRY = "monitor_evaluation"
    HEALTH_LATE_AFTER = 5.minutes

    Row = Data.define(:entry, :runner, :last_run_at, :next_fire, :buried_streak, :state)

    class << self
      # @return [Array<Row>] in config/schedule.yml order, and whether tuber
      #   was reachable to ask
      #
      # +runner+ is :tuber, :scheduler (bin/scheduler's rufus fallback),
      # :nobody, or :unknown when tuber can't be asked and no fallback is
      # running. +state+ is :ok, :pending (no run recorded since this process
      # started, and none due yet), :late (a whole cycle has passed without a
      # run), :stuck (tuber's fires are deduplicating against a buried job), or
      # :unscheduled (nothing fires it).
      def entries(now: Time.current)
        held = tuber_entries
        fallback = fallback_running?
        runs = ScheduleRun.last_runs

        Schedule.entries.map do |entry|
          stats = held&.dig(entry.name)
          runner =
            if stats then :tuber
            elsif fallback then :scheduler
            elsif held.nil? then :unknown
            else :nobody
            end
          last_run_at = runs[entry.name]
          next_fire = stats ? stats.next_fire : (entry.fugit.next_time(now).to_t if fallback)
          streak = stats&.buried_streak.to_i
          state =
            if runner == :nobody then :unscheduled
            elsif streak.positive? then :stuck
            elsif late?(entry, last_run_at, now) then :late
            elsif last_run_at.nil? then :pending
            else :ok
            end
          Row.new(entry:, runner:, last_run_at:, next_fire:, buried_streak: streak, state:)
        end
      end

      # {status: "ok" | "late", entry:, last_run_at:}. "late" means
      # HEALTH_ENTRY hasn't run for HEALTH_LATE_AFTER — counted from when this
      # process started if it has never run, so an instance where nothing ever
      # ran the schedule goes late too, a few minutes after boot.
      def health(now: Time.current)
        last = ScheduleRun.find_by(name: HEALTH_ENTRY)&.last_run_at
        since = last || booted_at
        {
          status: (now - since > HEALTH_LATE_AFTER) ? "late" : "ok",
          entry: HEALTH_ENTRY,
          last_run_at: last&.iso8601
        }
      end

      # A whole cycle has passed with no run: the entry was due at least twice
      # since it last ran (or since this process started, if it never has). One
      # missed fire is allowed for, since its job may be queued behind another
      # maintenance job sharing the con: key.
      def late?(entry, last_run_at, now)
        cron = entry.fugit
        due = cron.previous_time(now).to_t
        due_before = cron.previous_time(due).to_t
        (last_run_at || booted_at) < due_before
      end

      # When this process booted — the zero point for entries with no run on
      # record yet. A fresh install isn't late for its first cycle.
      def booted_at
        Rails.application.config.x.booted_at || Time.current
      end

      # Whether bin/scheduler is firing the schedule itself (Scheduler#tick).
      def fallback_running?
        Rails.cache.read(Scheduler::HEARTBEAT_KEY).present?
      rescue
        false
      end

      # {name => Tuber::StatStruct} for the entries tuber holds under
      # Schedule::OWNER; {} on a tuber with no recurring schedules; nil if tuber
      # can't be reached.
      def tuber_entries
        Ingest::Tuber.with_producer do |conn|
          conn.schedules.list(Schedule::OWNER).to_h do |_owner, name|
            [name, conn.schedules.stats(Schedule::OWNER, name)]
          end.compact
        end
      rescue ::Tuber::UnknownCommandError
        {}
      rescue => e
        Rails.logger.warn "[ScheduleStatus] couldn't ask tuber for the schedule: #{e.class}: #{e.message}"
        nil
      end
    end
  end
end
