class ApplicationController < ActionController::Base
  # Signing in, `current_user`, and the per-request `github` client. Every
  # action requires a signed-in user unless it calls `allow_unauthenticated_access`.
  include Authentication

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes
end
