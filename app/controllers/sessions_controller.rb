# frozen_string_literal: true

# Sign in and out. There is no password and no registration form: a Prism
# account is a GitHub account, created the first time someone completes the
# OAuth dance.
class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[new create failure]

  # The sign-in page. Already signed in → there is nothing to do here.
  def new
    redirect_to repos_path if signed_in?
  end

  # OmniAuth's callback. The middleware has already exchanged the code for a
  # token by the time we get here; `omniauth.auth` is the result.
  def create
    auth = request.env["omniauth.auth"]

    if auth.blank?
      redirect_to sign_in_path, alert: "GitHub didn't send an account back. Try signing in again."
      return
    end

    user = User.from_omniauth(auth)
    sign_in(user)
    redirect_to after_authentication_path, notice: "Signed in as #{user.login}."
  end

  # OmniAuth redirects here when the user declines, or GitHub refuses. The
  # message is GitHub's error key, so we say what to do rather than repeat it.
  def failure
    Rails.logger.info("OmniAuth failure: #{params[:message]} (strategy: #{params[:strategy]})")

    redirect_to sign_in_path,
                alert: "Signing in with GitHub didn't finish. Nothing was changed — try again."
  end

  def destroy
    sign_out
    redirect_to sign_in_path, notice: "Signed out.", status: :see_other
  end
end
