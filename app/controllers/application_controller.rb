class ApplicationController < ActionController::Base
  include Authentication
  include SplatAuthorization

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :set_current_attributes

  helper_method :queue_depth, :authorized_user?

  private

  def set_current_attributes
    Current.splat_host = ENV.fetch("SPLAT_HOST", "localhost:3000")
    Current.splat_internal_host = ENV.fetch("SPLAT_INTERNAL_HOST", nil)
  end

  def queue_depth
    @queue_depth ||= Rails.cache.fetch("tuber_ready_count", expires_in: 5.seconds) do
      Ingest::Tuber.queue_depth
    end
  end
end
