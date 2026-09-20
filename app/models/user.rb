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
  def self.from_omniauth(auth)
    user = find_or_initialize_by(github_id: dig_auth(auth, "uid").to_i)

    user.login = dig_auth(auth, "info", "nickname")
    user.name = dig_auth(auth, "info", "name").presence
    user.avatar_url = dig_auth(auth, "info", "image")
    user.access_token = dig_auth(auth, "credentials", "token")
    user.token_scopes = dig_auth(auth, "extra", "scope") || dig_auth(auth, "credentials", "scope")
    user.last_signed_in_at = Time.current

    user.save!
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

  # Called when GitHub answers 401: the token is dead and must never be retried.
  def revoke_token!
    update!(access_token: nil, token_scopes: nil)
  end

  def display_name = name.presence || login

  # Derived rather than stored: PLAN.md keeps the users table to the fields
  # sign-in actually produces, and a profile URL is always this shape.
  def html_url = "https://github.com/#{login}"

  def to_s = login
end
