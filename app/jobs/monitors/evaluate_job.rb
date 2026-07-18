# frozen_string_literal: true

module Monitors
  # Periodic sweep over the monitors table (scheduled in config/schedule.yml,
  # dispatched on splat.checkins — see Ingest::CheckInConsumer for why not
  # splat.maintenance). For each monitor it decides one of the failure kinds
  # below and drives the existing Issue alert path:
  #
  #   missed  — no check-in of any status within schedule + checkin_margin
  #             (the dead-man's switch)
  #   error   — the latest check-in reported status: error
  #   overrun — a run has been in_progress longer than max_runtime
  #
  # One Issue per (monitor, kind), keyed by a stable fingerprint. While the
  # issue is open nothing re-fires (the sweep runs every minute); resolving
  # happens automatically on recovery, so the next failure reopens the issue
  # and fires the "reopened" notification. Ignored issues stay ignored — the
  # standard "don't care" escape hatch silences a monitor.
  #
  # Cost: one SELECT over a tiny table per sweep, writes only on state
  # transitions — nothing per-check-in and nothing proportional to data volume.
  class EvaluateJob
    FAILURE_KINDS = %w[missed error overrun].freeze

    TITLES = {
      "missed" => ->(m) { "Monitor missed check-in: #{m.slug} (expected #{m.schedule_description})" },
      "error" => ->(m) { "Monitor reported error: #{m.slug}" },
      "overrun" => ->(m) { "Monitor overrun: #{m.slug} (in progress > #{m.max_runtime} min)" }
    }.freeze

    def perform
      now = Time.current
      CronMonitor.find_each do |monitor|
        evaluate(monitor, now)
      rescue => e
        Rails.logger.error "[Monitors::EvaluateJob] monitor=#{monitor.slug} failed: #{e.class}: #{e.message}"
      end
    end

    private

    def evaluate(monitor, now)
      failures = []
      failures << "missed" if monitor.missed?(now)
      failures << "error" if monitor.erroring?
      failures << "overrun" if monitor.overrun?(now)

      if failures.any?
        failures.each { |kind| open_issue!(monitor, kind, now) }
        update_state(monitor, failures.first)
      elsif monitor.last_checkin_at.present?
        resolve_issues!(monitor) if FAILURE_KINDS.include?(monitor.state)
        update_state(monitor, "ok")
      end
      # Never checked in and not yet overdue (or no schedule): stays "unknown".
    end

    def update_state(monitor, state)
      monitor.update_columns(state: state, updated_at: Time.current) if monitor.state != state
    end

    def fingerprint(monitor, kind)
      "monitor:#{monitor.slug}:#{kind}"
    end

    # Open (or reopen) the issue for this failure kind. An already-open issue
    # is left alone — that's the dedup. Ignored issues are respected.
    def open_issue!(monitor, kind, now)
      fp = fingerprint(monitor, kind)
      issue = Issue.find_by(project_id: monitor.project_id, fingerprint: fp)

      if issue.nil?
        Issue.create!(
          project_id: monitor.project_id,
          fingerprint: fp,
          title: TITLES.fetch(kind).call(monitor),
          exception_type: "Monitor#{kind.camelize}",
          status: :open,
          first_seen: now,
          last_seen: now
        )
      elsif issue.resolved?
        # Fires the "issue reopened" notification via Issue's callback.
        issue.update!(status: :open, last_seen: now)
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    # Recovery: close every open monitor issue for this slug. resolved! is
    # silent (no notification), so recover→fail cycles notify only on failure.
    def resolve_issues!(monitor)
      fps = FAILURE_KINDS.map { |kind| fingerprint(monitor, kind) }
      Issue.where(project_id: monitor.project_id, fingerprint: fps, status: :open)
        .find_each(&:resolved!)
    end
  end
end
