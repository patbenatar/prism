# frozen_string_literal: true

# Namespace for everything that talks to GitHub, plus the error hierarchy that
# Github::Client normalizes Octokit and GraphQL failures into.
#
# These live here rather than in `github/errors.rb` because Zeitwerk maps that
# path to the constant `Github::Errors`, and PLAN.md specifies flat names
# (`Github::Unauthorized`). A namespace file is the idiomatic Zeitwerk home for
# constants that belong to the namespace itself.
#
# Nothing outside this namespace should rescue an `Octokit::Error` or inspect an
# HTTP status: controllers rescue these.
module Github
  # Base class. Everything the client raises is a Github::Error, so a controller
  # can `rescue Github::Error` as a catch-all and still special-case below it.
  class Error < StandardError
    attr_reader :status, :response_body, :documentation_url

    def initialize(message = nil, status: nil, response_body: nil, documentation_url: nil)
      super(message)
      @status = status
      @response_body = response_body
      @documentation_url = documentation_url
    end

    # Shown to the user. Subclasses override where GitHub's own wording is
    # unhelpful or leaks API vocabulary.
    def user_message = message
  end

  # 401. Always fatal for the session: clear the stored token and send the user
  # back to sign in.
  #
  # The old wording here said the sign-in had "expired", which taught people
  # something untrue. OAuth App tokens do not expire (docs/research/github-api.md
  # §1.3) — one stops working because it was revoked, or because
  # re-authorizing the app somewhere else re-issued it. So say only what we
  # actually know: GitHub refused this token, and signing in replaces it.
  class Unauthorized < Error
    def user_message = "GitHub refused your sign-in. Signing in again will replace it."
  end

  # 403 that is not a rate limit — the token lacks the scope, or the user lacks
  # permission on the repository.
  class Forbidden < Error
    def user_message = "GitHub refused that request. You may not have access to this repository."
  end

  # 404. Also what GitHub returns for a private resource the token cannot see,
  # so never render this as "deleted".
  class NotFound < Error
    def user_message = "Not found on GitHub, or you don't have access to it."
  end

  # 403/429 from a primary or secondary rate limit.
  class RateLimited < Error
    attr_reader :reset_at, :retry_after

    def initialize(message = nil, reset_at: nil, retry_after: nil, **options)
      super(message, **options)
      @reset_at = reset_at
      @retry_after = retry_after
    end

    # Seconds to wait, from whichever signal GitHub gave us.
    def retry_in
      return retry_after if retry_after
      return unless reset_at

      [ (reset_at - Time.current).ceil, 0 ].max
    end

    def user_message
      seconds = retry_in
      return "GitHub is rate limiting us. Try again in a moment." if seconds.nil?

      "GitHub is rate limiting us. Try again in #{ActiveSupport::Duration.build(seconds).inspect}."
    end
  end

  # 422 whose message includes "must be part of the diff" — the anchor line is
  # not inside any hunk of the file's patch. Review::AnchorResolver validates
  # before we write, so this should be unreachable; if it fires, the UI offers
  # the file-level fallback.
  class LineNotCommentable < Error
    def user_message
      "GitHub only accepts comments on lines that appear in this pull request's diff. " \
        "Leave a file-level comment instead."
    end
  end

  # Any other 422. Carries GitHub's own validation messages so the composer can
  # show them inline without inventing wording.
  class Unprocessable < Error
    attr_reader :errors

    def initialize(message = nil, errors: [], **options)
      super(message, **options)
      @errors = errors
    end
  end

  # GraphQL returned HTTP 200 with a non-empty `errors` array. Github::GraphQL
  # raises this; Octokit never will, because it only looks at the status.
  class GraphQLError < Error
    attr_reader :errors

    def initialize(message = nil, errors: [], **options)
      super(message, **options)
      @errors = errors
    end

    # GraphQL error extensions carry a machine-readable `type` such as
    # "NOT_FOUND" or "FORBIDDEN" on the first error.
    def type = errors.first && (errors.first["type"] || errors.first.dig("extensions", "code"))
  end

  # 5xx, a timeout, or a connection failure. Retryable in principle; v1 just
  # surfaces it.
  class Unavailable < Error
    def user_message = "GitHub is unavailable right now. Try again shortly."
  end
end
