# frozen_string_literal: true

# Session handling for the whole app.
#
# There is no password and no sessions table: signing in means completing the
# GitHub OAuth dance, and the session cookie holds nothing but a user id. Every
# GitHub request is then made with that user's token, so authorization is
# GitHub's and Prism never has to decide who may see what.
#
# Controllers get `github` — a Github::Client bound to the current user and
# memoized for the request — and should never build one themselves.
module Authentication
  extend ActiveSupport::Concern

  included do
    helper_method :current_user, :signed_in?

    before_action :require_authentication

    # A revoked token can surface on any action, so handle it once here rather
    # than in every controller.
    #
    # By the time a Github::Unauthorized reaches this, Github::Client has
    # already tried renewing the token and either had nothing to renew with or
    # been told by GitHub that the grant is over. An *expired* token no longer
    # arrives here at all — it is replaced before the request is replayed. So
    # this handler still means what it says: signing in again is the fix.
    rescue_from Github::Unauthorized, with: :handle_revoked_token
  end

  class_methods do
    # Opt an action out of the sign-in requirement.
    #
    #   allow_unauthenticated_access only: %i[new create failure]
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private

  def current_user
    return @current_user if defined?(@current_user)

    @current_user = session[:user_id] && User.find_by(id: session[:user_id])
  end

  def signed_in? = current_user.present?

  def require_authentication
    signed_in? || request_authentication
  end

  def request_authentication
    store_return_path
    redirect_to sign_in_path,
                alert: "Sign in with GitHub to continue.",
                status: redirect_status
  end

  # Send the user back where they were headed once they finish signing in, but
  # only for a GET — replaying a POST after a redirect is never what they meant.
  def store_return_path
    session[:return_to] = (request.get? || request.head?) ? request.fullpath : nil
  end

  def after_authentication_path = session.delete(:return_to).presence || root_path

  # reset_session guards against session fixation: the pre-login session id must
  # not survive the privilege change. That wipes the stored return path too, so
  # carry it across by hand — otherwise every sign-in lands on the root page and
  # the "take me back where I was" behaviour silently never fires.
  def sign_in(user)
    return_to = session[:return_to]

    reset_session
    session[:return_to] = return_to if return_to.present?
    session[:user_id] = user.id
    @current_user = user
  end

  def sign_out
    reset_session
    @current_user = nil
  end

  # One client per request. Building a second would mean a second Octokit
  # connection and a second cache keyspace for no benefit.
  def github
    @github ||= Github::Client.new(current_user)
  end

  # GitHub said the token is dead and could not be renewed. Drop the whole
  # grant so we never retry with it, end the session, and send the user back
  # to sign in.
  def handle_revoked_token(error)
    current_user&.revoke_token!
    sign_out
    redirect_to sign_in_path, alert: error.user_message, status: redirect_status
  end

  # Turbo follows a redirect from a non-GET request only when it is a 303.
  def redirect_status = (request.get? || request.head?) ? :found : :see_other
end
