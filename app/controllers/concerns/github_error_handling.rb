# frozen_string_literal: true

# Turns the two GitHub failures a browsing screen can hit into pages rather
# than exceptions.
#
# `Github::Unauthorized` is not here on purpose: the Authentication concern
# already handles a dead token for every controller by signing the user out.
# What is left is the pair a reviewer meets in normal use —
#
#   NotFound     the repository or pull request doesn't exist, or the token
#                can't see it. GitHub returns 404 for both, and so do we: not
#                confirming a private repository exists is the point.
#   RateLimited  GitHub is throttling this token. Nothing rendered, so this is
#                a page rather than a banner, and it says when to come back.
#
# Include it in a controller that reads from GitHub.
module GithubErrorHandling
  extend ActiveSupport::Concern

  included do
    rescue_from Github::NotFound, with: :github_not_found
    rescue_from Github::Forbidden, with: :github_forbidden
    rescue_from Github::RateLimited, with: :github_rate_limited
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

  def github_rate_limited(error)
    # GitHub sends either a retry-after header or a reset timestamp; the error
    # normalises both into retry_in seconds and keeps reset_at as a fallback.
    @retry_in = error.try(:retry_in)
    @reset_at = error.try(:reset_at)
    render "shared/rate_limited", status: :too_many_requests, formats: :html
  end
end
