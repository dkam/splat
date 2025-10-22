# frozen_string_literal: true

class HealthController < ApplicationController
  def show
    # Calculate transaction rates
    transactions_last_minute = Transaction.where("timestamp > ?", 1.minute.ago).count
    transactions_last_hour = Transaction.where("timestamp > ?", 1.hour.ago).count

    render json: {
      status: "ok",
      timestamp: Time.current.iso8601,
      queue_depth: SolidQueue::ReadyExecution.count,
      event_count: Event.count,
      issue_count: Issue.where(status: "open").count,
      transaction_count: Transaction.count,
      transactions_per_second: (transactions_last_minute / 60.0).round(2),
      transactions_per_minute: (transactions_last_hour / 60.0).round(2)
    }
  end
end
