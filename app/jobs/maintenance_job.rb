class MaintenanceJob < ApplicationJob
  queue_as :default

  def perform
    cleanup_finished_jobs
  end

  private

  def cleanup_finished_jobs
    # Delete finished jobs older than 7 days
    cutoff = 7.days.ago
    deleted_count = SolidQueue::Job.finished.where("finished_at < ?", cutoff).delete_all
    Rails.logger.info "Maintenance: Deleted #{deleted_count} finished jobs older than #{cutoff}"
  end
end
