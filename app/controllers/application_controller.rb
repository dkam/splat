class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :set_current_attributes

  helper_method :queue_depth

  private

  def set_current_attributes
    Current.splat_host = ENV.fetch("SPLAT_HOST", "localhost:3030")
    Current.splat_internal_host = ENV.fetch("SPLAT_INTERNAL_HOST", nil)
  end

  def queue_depth
    @queue_depth ||= SolidQueue::ReadyExecution.count
  end
end
