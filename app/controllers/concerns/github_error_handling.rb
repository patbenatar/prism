# frozen_string_literal: true

# Turns the GitHub failures a browsing screen can hit into pages rather than
# exceptions.
#
# `Github::Unauthorized` is not here on purpose: the Authentication concern
# already handles a dead token for every controller by signing the user out.
# What is left is what a reviewer meets in normal use —
#
#   NotFound     the repository or pull request doesn't exist, or the token
#                can't see it. GitHub returns 404 for both, and so do we: not
#                confirming a private repository exists is the point.
#   RateLimited  GitHub is throttling this token. Nothing rendered, so this is
#                a page rather than a banner, and it says when to come back.
#   Unavailable  a 5xx, a timeout, or a connection failure. Nothing is wrong
#                with what the reviewer asked for, so this must not read like
#                the 404 — and it is the one error where "try again" is
#                genuinely the right advice rather than a shrug.
#
# Include it in a controller that reads from GitHub.
module GithubErrorHandling
  extend ActiveSupport::Concern

  included do
    rescue_from Github::NotFound, with: :github_not_found
    rescue_from Github::Forbidden, with: :github_forbidden
    rescue_from Github::RateLimited, with: :github_rate_limited
    rescue_from Github::Unavailable, with: :github_unavailable
  end

  private

  def github_not_found(_error)
    render "shared/not_found", status: :not_found, formats: :html
  end

  # A 403 that isn't a rate limit is usually a repository whose org hasn't
  # approved the OAuth app. Same page, different explanation.
  def github_forbidden(error)
    @forbidden_message = error.try(:user_message).presence || error.message
    render "shared/forbidden", status: :forbidden, formats: :html
  end

  # 5xx / timeout / connection failure. `Review::PullRequestPage` already
  # settles the per-file content fetches and the threads read individually, so
  # a partial outage degrades rather than lands here; what reaches this is the
  # pull request itself, the file list, or a repository read — the calls with
  # nothing left to render without.
  #
  # "Try again" has to point somewhere a browser can navigate to. On a read
  # that is this same page; on a write it is whatever screen the write came
  # from, which only the controller knows (see github_retry_path). `head?` is
  # in the question because Rails routes HEAD like GET and answers it with the
  # same handler — `get?` alone is false there, which would hand a HEAD of
  # this page the write branch's answer.
  def github_unavailable(_error)
    navigable = request.get? || request.head?
    @retry_path = navigable ? request.fullpath : github_retry_path
    @retry_label = @retry_path == repos_path ? "Back to repositories" : "Try again"
    render "shared/unavailable", status: :service_unavailable, formats: :html
  end

  # Where "try again" sends someone whose *write* failed — overridden by the
  # controllers that know which screen it was written from.
  def github_retry_path = repos_path

  def github_rate_limited(error)
    # GitHub sends either a retry-after header or a reset timestamp; the error
    # normalises both into retry_in seconds and keeps reset_at as a fallback.
    @retry_in = error.try(:retry_in)
    @reset_at = error.try(:reset_at)
    render "shared/rate_limited", status: :too_many_requests, formats: :html
  end
end
