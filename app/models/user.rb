# frozen_string_literal: true

# The only persisted record in Prism.
#
# A user is a GitHub identity plus the OAuth token we act on their behalf with.
# Everything a reviewer actually works on — repositories, pull requests, files,
# comments, reviews, threads — stays on GitHub and is fetched per request, so
# there is nothing here that can drift out of sync.
class User < ApplicationRecord
  # The token is the crown jewel: it carries the `repo` scope, which is full
  # read and write over every repository this person can reach. Non-deterministic
  # encryption (the default) is right because we never query by it.
  encrypts :access_token

  # The refresh token is the *longer-lived* crown jewel — it mints access
  # tokens for six months without anybody being asked again — so it gets
  # exactly the same treatment. See Github::Credentials for what spends it.
  encrypts :refresh_token

  has_many :pinned_repos, dependent: :destroy

  # Repositories this person asked Prism to watch. Prism acts on GitHub as
  # them when a webhook fires, so the token above is what makes a subscription
  # work — and what makes it stop working when it is revoked.
  has_many :webhook_subscriptions, dependent: :destroy


  normalizes :login, with: ->(value) { value.to_s.strip }
  normalizes :token_scopes, with: ->(value) { normalize_scopes(value) }

  validates :github_id, presence: true, uniqueness: true
  validates :login, presence: true

  # There is no narrower OAuth scope that permits writing pull request review
  # comments, so this one scope gates the entire write path.
  WRITE_SCOPE = "repo"

  # Upsert from an OmniAuth::AuthHash. Matched on GitHub's numeric id rather
  # than the login, because a login can be renamed and reused.
  #
  # Note the scope lives under `extra`, not `credentials`: omniauth-github's
  # strategy exposes it as `extra.scope` from the token response.
  #
  # ## What `credentials` actually contains, and why both shapes matter
  #
  # omniauth-oauth2 builds it (strategies/oauth2.rb) as:
  #
  #   {"token" => …}
  #   + "refresh_token" if the token expires *and* one came back
  #   + "expires_at"    if the token expires
  #   + "expires"       always, true or false
  #
  # So an OAuth App with "Expire user authorization tokens" **on** — which is
  # what production is — yields `token`, `refresh_token`, `expires_at` (an
  # Integer, unix epoch, our clock plus GitHub's `expires_in`) and
  # `expires: true`. An OAuth App with it **off** yields `token` and
  # `expires: false`, and nothing else. Development is a separate registration
  # and may be either, which is precisely why both shapes have to work.
  #
  # A sign-in is authoritative about the credential, including when it says
  # there is no refresh token: writing back what GitHub just handed us keeps
  # the three columns describing one grant rather than a mixture of two.
  def self.from_omniauth(auth)
    user = find_or_initialize_by(github_id: dig_auth(auth, "uid").to_i)

    user.login = dig_auth(auth, "info", "nickname")
    user.name = dig_auth(auth, "info", "name").presence
    user.avatar_url = dig_auth(auth, "info", "image")
    user.access_token = dig_auth(auth, "credentials", "token")
    user.refresh_token = dig_auth(auth, "credentials", "refresh_token").presence
    user.access_token_expires_at = parse_expires_at(dig_auth(auth, "credentials", "expires_at"))
    user.token_scopes = dig_auth(auth, "extra", "scope") || dig_auth(auth, "credentials", "scope")
    user.last_signed_in_at = Time.current

    user.save!

    # A fresh sign-in is the fix for the commonest way webhook watching
    # breaks, and the person doing it is usually here for something else
    # entirely, with no idea a delivery was refused days ago. So apply it
    # rather than wait to be asked.
    #
    # Keyed on the sign-in, not on the token changing. GitHub may hand back
    # the same token when the grant is unchanged, and Active Record compares
    # decrypted values for dirty tracking, so "did access_token change?" is
    # false exactly when someone signs in to fix things and nothing was
    # re-issued. Completing the OAuth dance is itself the proof the token
    # works — that is the event worth reacting to.
    user.revive_webhook_subscriptions!
    user
  end

  # Works with an OmniAuth::AuthHash (string keys, method access) and with the
  # plain nested hash a test might build.
  def self.dig_auth(auth, *path)
    auth.to_hash.with_indifferent_access.dig(*path)
  rescue NoMethodError
    auth.dig(*path)
  end
  private_class_method :dig_auth

  # omniauth hands this over as an Integer of unix seconds; a hand-built auth
  # hash in a test may well use a Time, and a stray string should not raise on
  # the sign-in path. Anything unreadable becomes nil, which simply means "we
  # were not told when this expires" — the same as a non-expiring token.
  def self.parse_expires_at(value)
    case value
    when nil then nil
    when Numeric then Time.zone.at(value)
    when Time, DateTime, ActiveSupport::TimeWithZone then value
    else Time.zone.parse(value.to_s)
    end
  rescue ArgumentError, TypeError
    nil
  end
  private_class_method :parse_expires_at

  def self.normalize_scopes(value)
    Array(value).flat_map { |part| part.to_s.split(/[,\s]+/) }
                .map(&:strip)
                .reject(&:empty?)
                .uniq
                .join(",")
                .presence
  end

  # The scopes GitHub actually granted, which can be narrower than what we asked
  # for if the user's org restricts the app.
  def scopes = token_scopes.to_s.split(",")

  # False means the UI should read-only itself rather than let someone write a
  # comment that GitHub will reject.
  def can_write_reviews? = scopes.include?(WRITE_SCOPE)

  def token? = access_token.present?

  # Can Prism get a working access token without this person being present?
  #
  # False for every row that predates expiring tokens and for every sign-in
  # through an OAuth App that does not issue them — those behave exactly as
  # they always have, which is the point.
  def refreshable? = refresh_token.present?

  # Called once GitHub has refused the token **and** there is no way left to
  # renew it — either there never was a refresh token, or Github::Credentials
  # spent it and GitHub said the grant is over. Only a fresh sign-in fixes it
  # from here, so everything that made up the old grant goes together: a
  # refresh token left behind next to a cleared access token would be spent on
  # the next request and rejected all over again.
  def revoke_token!
    update!(access_token: nil, refresh_token: nil, access_token_expires_at: nil, token_scopes: nil)
  end

  def display_name = name.presence || login

  # Derived rather than stored: PLAN.md keeps the users table to the fields
  # sign-in actually produces, and a profile URL is always this shape.
  def html_url = "https://github.com/#{login}"

  def to_s = login

  # Clears a failure caused by GitHub refusing this account, now that it
  # plainly is not refusing it any more — and then goes back for the work that
  # was missed while it was.
  #
  # Both halves matter, and the second one is the one that was missing.
  # Reviving a subscription only means the *next* delivery will be handled;
  # the deliveries GitHub sent while the token was dead are gone, and nothing
  # redelivers them. So a fresh sign-in also queues a reconciliation pass,
  # which asks GitHub what the repository's open pull requests look like and
  # fixes whatever Prism should have done and didn't.
  #
  # `revivable` rather than `suspended`: a subscription Prism gave up on comes
  # back too, provided a credential is what broke it. That is exactly the case
  # a sign-in is evidence about. See WebhookSubscription::CREDENTIAL.
  def revive_webhook_subscriptions!
    webhook_subscriptions.revivable.find_each do |subscription|
      subscription.revive_after_new_token!
      Webhooks::ReconcileSubscriptionJob.perform_later(subscription.id)
    end
  end
end
