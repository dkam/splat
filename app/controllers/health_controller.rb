# frozen_string_literal: true

class HealthController < ApplicationController
  def show
    render json: {
      status: "ok",
      timestamp: Time.current.iso8601,
      queue_depth: SolidQueue::Job.pending.count,
      event_count: Event.count,
      issue_count: Issue.where(status: "unresolved").count,
      transaction_count: Transaction.count
    }
  end
end
