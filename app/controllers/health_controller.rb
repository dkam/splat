# frozen_string_literal: true

class HealthController < ApplicationController
  skip_before_action :require_authentication

  # Queue depth threshold for health checks
  # If queue depth exceeds this, set queue_status to "warning" or "critical"
  QUEUE_WARNING_THRESHOLD = ENV.fetch("QUEUE_WARNING_THRESHOLD", 50).to_i
  QUEUE_CRITICAL_THRESHOLD = ENV.fetch("QUEUE_CRITICAL_THRESHOLD", 100).to_i

  def show
    queue_depth = SolidQueue::ReadyExecution.count
    counts = Rails.cache.fetch("health_counts", expires_in: 30.seconds) do
      {
        transactions_last_minute: Transaction.where("timestamp > ?", 1.minute.ago).count,
        transactions_last_hour: Transaction.where("timestamp > ?", 1.hour.ago).count,
        events_24h: Event.where("timestamp > ?", 24.hours.ago).count,
        open_issues: Issue.where(status: "open").count,
        transactions_24h: Transaction.where("timestamp > ?", 24.hours.ago).count
      }
    end

    render json: {
      status: overall_status(queue_depth),
      timestamp: Time.current.iso8601,
      queue_depth: queue_depth,
      queue_status: queue_status(queue_depth),
      event_count: counts[:events_24h],
      event_count_window: "24h",
      issue_count: counts[:open_issues],
      transaction_count: counts[:transactions_24h],
      transaction_count_window: "24h",
      transactions_per_second: (counts[:transactions_last_minute] / 60.0).round(2),
      transactions_per_minute: (counts[:transactions_last_hour] / 60.0).round(2)
    }
  end

  private

  def queue_status(depth)
    if depth >= QUEUE_CRITICAL_THRESHOLD
      "critical"
    elsif depth >= QUEUE_WARNING_THRESHOLD
      "warning"
    else
      "healthy"
    end
  end

  def overall_status(queue_depth)
    # Overall status is "ok" unless queue is critical
    queue_depth >= QUEUE_CRITICAL_THRESHOLD ? "degraded" : "ok"
  end
end
