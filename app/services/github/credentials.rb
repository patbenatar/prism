# frozen_string_literal: true

require "net/http"

module Github
  # The one place that answers "what token should I use for this person, right
  # now?" — and renews it when the answer is "none that still works".
  #
  # ## Why this exists
  #
  # Prism's OAuth App issues **expiring** user tokens: eight hours, with a
  # refresh token that lasts six months and rotates on every use. Without this
  # module a sign-in bought exactly one working day, and a background job that
  # ran on hour nine got a 401 with nobody there to see it. The session cookie
  # never noticed — Prism's own session is its own — so the symptom was not
  # "you were signed out", it was "everything GitHub silently stopped working".
  #
  # ## The contract
  #
  #   token_for(user)        a token that should work. Refreshes first if the
  #                          stored one is expired or close enough to it.
  #   refresh(user, used:)   renew now, because GitHub just refused `used`.
  #
  # Both return the token to use. Both raise `Github::Unauthorized` when the
  # grant is genuinely over (the person must sign in again) and
  # `Github::Unavailable` when GitHub could not be reached to ask — a
  # distinction the callers depend on, because the first ends a session and
  # the second must not.
  #
  # A user with no refresh token — every row that predates this, and every row
  # from an OAuth App with expiry switched off — flows straight through
  # untouched. Nothing refreshes, nothing is written, and a 401 means what it
  # has always meant.
  #
  # ## This is the exception to "Github::Client is the only thing that talks
  # ## to GitHub"
  #
  # It talks to `github.com`, not `api.github.com`, and it is not an API call:
  # it is the OAuth token endpoint, the same one omniauth POSTs to during
  # sign-in. Octokit has no vocabulary for it and no token to make it with —
  # the whole point is that we do not have a working token. Hence a bare
  # Net::HTTP POST, and hence the errors being translated into the same
  # `Github::Error` hierarchy everything else in the app already rescues.
  module Credentials
    # Not api.github.com. The token endpoint lives on the web host.
    TOKEN_URL = "https://github.com/login/oauth/access_token"

    # How early to renew.
    #
    # `access_token_expires_at` is not a timestamp GitHub handed us about its
    # own clock — it is *our* clock plus the `expires_in` duration GitHub
    # quoted, computed at sign-in (see User.token_expires_at). So comparing it
    # to `Time.current` compares our clock with itself, and the equality trick
    # Webhooks::Reconciler#settled? uses to avoid a cross-clock comparison
    # does not apply and is not needed here.
    #
    # What the margin buys is the gap between deciding a token is good and
    # finishing the request that uses it: a slow page that makes a dozen
    # GitHub calls, a job that was queued a moment ago, the round trip itself.
    # Five minutes out of eight hours costs one extra refresh a day and
    # removes the whole class of "it was valid when we checked".
    REFRESH_MARGIN = 5.minutes

    # A refresh must not be able to hold a row lock open indefinitely — every
    # other thread wanting this user's token is queued behind it.
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10

    # The token endpoint answers **HTTP 200 with an error in the body**, so the
    # status code tells us almost nothing and these strings tell us everything.
    #
    # Deliberately only two. `bad_refresh_token` and `invalid_grant` are the
    # ones that mean *this person's* grant is finished and only a fresh sign-in
    # will do. Everything else — `incorrect_client_credentials` above all —
    # is a fault of ours, not theirs, and is treated as transient: signing
    # every user in the system out because a deploy shipped the wrong client
    # secret would turn a five-minute rollback into a support incident.
    REJECTED = %w[bad_refresh_token invalid_grant].freeze

    # Everything that means "we never got an answer", as opposed to "GitHub
    # answered no". Net::OpenTimeout and Net::ReadTimeout are both
    # Timeout::Error, so the two constants above are covered here.
    NETWORK_ERRORS = [
      Timeout::Error, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
      SocketError, OpenSSL::SSL::SSLError, IOError
    ].freeze

    # What GitHub sends back, normalized.
    Tokens = Data.define(:access_token, :refresh_token, :expires_at)

    class << self
      # A token that should work for the next call.
      def token_for(user)
        token = user&.access_token
        return token unless user&.refreshable?
        return token unless stale?(user)

        refresh(user, used: token)
      end

      # Renew now. `used:` is the token that just failed, and it is how a
      # thread that loses the race recognises that it lost: if the row no
      # longer holds the token we tried, somebody else already replaced it and
      # theirs is the one to use.
      #
      # ## The concurrency problem, and why a row lock is the answer
      #
      # Refresh tokens are single-use. GitHub invalidates the one you spent
      # and hands back a new one, so two concurrent refreshes with the same
      # refresh token means the second gets `bad_refresh_token` — and if it
      # believed that answer it would clear a credential the winner had just
      # made perfectly good, signing the user out at exactly the moment the
      # system repaired itself.
      #
      # Prism has three Puma threads and, in production, Solid Queue running
      # *inside* Puma. A browser request and a webhook delivery racing for one
      # user's token is not a thought experiment, it is a Tuesday.
      #
      # `with_lock` takes `SELECT … FOR UPDATE` on the user row inside a
      # transaction. The loser blocks until the winner commits, then re-reads
      # the row it is holding the lock on and finds the new token already
      # there — so it never spends the dead refresh token at all. The "losing
      # refresh re-reads and uses what the winner stored" strategy falls out
      # of the lock rather than being bolted on beside it.
      #
      # The cost is that one HTTP round trip happens under a row lock. That is
      # why the timeouts above are short and why the check inside the lock is
      # the first thing in the block: the common case reads one row and
      # returns.
      #
      # ## Why this mutates the caller's User rather than its own copy
      #
      # `with_lock` reloads the object it is given, so a refresh updates the
      # row the caller is holding. That is deliberate.
      # Review::PullRequestPage fans a page's file reads out over worker
      # threads and builds each worker a client from **the same User object**,
      # so without it every worker would take the lock in turn to discover
      # somebody else had already refreshed. With it, the first one through
      # leaves a fresh token in the object and the rest never reach the lock
      # at all. The same goes for `revoke_token!`: the caller's object learns
      # immediately that there is nothing left to renew with, instead of
      # queueing up to be told.
      def refresh(user, used: nil)
        return user&.access_token unless user&.refreshable?

        outcome =
          user.with_lock do
            # with_lock reloaded the row. Everything below sees committed state.
            if superseded?(user, used)
              [ :token, user.access_token ]
            elsif user.refresh_token.blank?
              [ :token, user.access_token ]
            else
              exchange_within_lock(user)
            end
          end

        raise outcome.last if outcome.first == :rejected

        outcome.last
      end

      # True when the stored token is expired, near enough to expiry to be
      # worth replacing, or missing entirely.
      #
      # A null `access_token_expires_at` means "we were never told this token
      # expires", which is the truth for a non-expiring OAuth App and for
      # every row written before Prism captured the expiry. Those are never
      # stale on a clock; they go dead the way they always have, by GitHub
      # refusing them.
      def stale?(user)
        return true if user.access_token.blank?

        expires_at = user.access_token_expires_at
        expires_at.present? && expires_at <= REFRESH_MARGIN.from_now
      end

      private

      # Did another thread replace the token while we were waiting for the
      # lock? Only meaningful when the caller told us what it tried.
      def superseded?(user, used)
        used.present? && user.access_token.present? && user.access_token != used
      end

      # Runs inside the row lock and inside the transaction, which is why a
      # rejection is *returned* rather than raised: raising here would roll
      # back the very write that records the credential as finished, and the
      # next caller would spend the dead refresh token all over again.
      #
      # A transient failure does raise, and rolling back is exactly right for
      # it — nothing was written, and the stored credential is still the best
      # one we have.
      def exchange_within_lock(user)
        [ :token, store(user, exchange(user.refresh_token)) ]
      rescue Github::Unauthorized => error
        user.revoke_token!
        [ :rejected, error ]
      end

      # Persist the whole new pair before anybody uses any of it. The refresh
      # token we just spent is already dead on GitHub's side; if the process
      # died between the exchange and the write, the user would have to sign
      # in again — so the write is the first thing that happens with the
      # answer, not the last.
      def store(user, tokens)
        user.update!(
          access_token: tokens.access_token,
          # GitHub always rotates it, but if a response ever arrives without
          # one, keeping the old is the only non-destructive reading.
          refresh_token: tokens.refresh_token.presence || user.refresh_token,
          access_token_expires_at: tokens.expires_at
        )
        user.access_token
      end

      def exchange(refresh_token)
        client_id = ENV["GITHUB_CLIENT_ID"].to_s
        client_secret = ENV["GITHUB_CLIENT_SECRET"].to_s

        # Not Unauthorized: nothing is wrong with the person's grant, and
        # signing them out would destroy a refresh token that is still good.
        if client_id.empty? || client_secret.empty?
          raise Unavailable, "Prism has no GitHub OAuth credentials configured, so it cannot renew a token."
        end

        parse(post_token_request(client_id, client_secret, refresh_token))
      end

      def post_token_request(client_id, client_secret, refresh_token)
        uri = URI(TOKEN_URL)
        request = Net::HTTP::Post.new(uri)
        request["Accept"] = "application/json"
        request["User-Agent"] = "Prism"
        request.set_form_data(
          client_id: client_id,
          client_secret: client_secret,
          grant_type: "refresh_token",
          refresh_token: refresh_token
        )

        Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
                        open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
          http.request(request)
        end
      rescue *NETWORK_ERRORS => error
        raise Unavailable, "Could not reach GitHub to renew the token: #{error.message}"
      end

      def parse(response)
        # A 5xx or a 404 from the token endpoint is GitHub having a bad day,
        # never a verdict on the refresh token.
        unless response.is_a?(Net::HTTPSuccess)
          raise Unavailable.new("GitHub answered the token endpoint with #{response.code}.",
                                status: response.code.to_i, response_body: response.body)
        end

        payload = JSON.parse(response.body.to_s)
        raise Unavailable.new("GitHub's token response was not an object.", response_body: response.body) unless payload.is_a?(Hash)

        raise_token_error(payload) if payload["error"].present?

        access_token = payload["access_token"].to_s
        raise Unavailable.new("GitHub's token response carried no access token.", response_body: payload) if access_token.empty?

        Tokens.new(
          access_token: access_token,
          refresh_token: payload["refresh_token"].presence,
          expires_at: expires_at_from(payload["expires_in"])
        )
      rescue JSON::ParserError
        raise Unavailable.new("GitHub's token response was not JSON.", response_body: response.body)
      end

      def raise_token_error(payload)
        code = payload["error"].to_s
        detail = payload["error_description"].presence || code
        documentation_url = payload["error_uri"].presence

        if REJECTED.include?(code)
          raise Unauthorized.new(detail, response_body: payload, documentation_url: documentation_url)
        end

        raise Unavailable.new("GitHub refused to renew the token (#{code}): #{detail}",
                              response_body: payload, documentation_url: documentation_url)
      end

      # Our clock plus GitHub's quoted duration. A response with no
      # `expires_in` means the app is not issuing expiring tokens for this
      # grant, and null is the honest record of that.
      def expires_at_from(expires_in)
        seconds = expires_in.to_i
        return nil unless seconds.positive?

        Time.current + seconds
      end
    end
  end
end
