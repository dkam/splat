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
    # SPLAT_HOST wins when set: the externally reachable authority can differ
    # from the one being browsed (proxied deploys, Tailscale). Unset, fall back
    # to the authority of the request itself rather than a hardcoded
    # localhost:3000, so a server on a non-default port hands out a DSN that
    # points back at itself. Jobs and mailers have no request, and keep reading
    # ENV (see Current.splat_host).
    Current.splat_host = ENV["SPLAT_HOST"].presence || request.host_with_port
    Current.splat_internal_host = ENV.fetch("SPLAT_INTERNAL_HOST", nil)
  end

  def queue_depth
    @queue_depth ||= Rails.cache.fetch("tuber_ready_count", expires_in: 5.seconds) do
      Ingest::Tuber.queue_depth
    end
  end
end
