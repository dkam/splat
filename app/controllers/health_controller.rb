# frozen_string_literal: true

class HealthController < ApplicationController
  # Queue depth threshold for health checks
  # If queue depth exceeds this, set queue_status to "warning" or "critical"
  QUEUE_WARNING_THRESHOLD = ENV.fetch("QUEUE_WARNING_THRESHOLD", 50).to_i
  QUEUE_CRITICAL_THRESHOLD = ENV.fetch("QUEUE_CRITICAL_THRESHOLD", 100).to_i

  def show
    # Calculate transaction rates
    transactions_last_minute = Transaction.where("timestamp > ?", 1.minute.ago).count
    transactions_last_hour = Transaction.where("timestamp > ?", 1.hour.ago).count

    queue_depth = SolidQueue::ReadyExecution.count

    render json: {
      status: overall_status(queue_depth),
      timestamp: Time.current.iso8601,
      queue_depth: queue_depth,
      queue_status: queue_status(queue_depth),
      event_count: Event.count,
      issue_count: Issue.where(status: "open").count,
      transaction_count: Transaction.count,
      transactions_per_second: (transactions_last_minute / 60.0).round(2),
      transactions_per_minute: (transactions_last_hour / 60.0).round(2)
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
