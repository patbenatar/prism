# frozen_string_literal: true

require "test_helper"

class UserTest < ActiveSupport::TestCase
  include AuthenticationHelpers

  test "access_token is encrypted at rest" do
    user = users(:prism_dev)

    assert_equal "gho_test_token_prism_dev", user.access_token

    ciphertext = User.connection.select_value(
      "SELECT access_token FROM users WHERE id = #{user.id}"
    )
    assert_not_equal "gho_test_token_prism_dev", ciphertext
    assert_no_match(/gho_test_token_prism_dev/, ciphertext.to_s)
  end

  test "from_omniauth creates a user from the auth hash" do
    auth = github_auth_hash(
      User.new(github_id: 12345, login: "newcomer", name: "New Comer",
               avatar_url: "https://avatars.example/12345", access_token: "gho_fresh"),
      scope: "repo,read:org,read:user"
    )

    user = nil
    assert_difference -> { User.count }, 1 do
      user = User.from_omniauth(auth)
    end

    assert_equal 12_345, user.github_id
    assert_equal "newcomer", user.login
    assert_equal "New Comer", user.name
    assert_equal "https://avatars.example/12345", user.avatar_url
    assert_equal "gho_fresh", user.access_token
    assert_equal "repo,read:org,read:user", user.token_scopes
    assert_in_delta Time.current, user.last_signed_in_at, 5
  end

  # ------------------------------------------- the two shapes of credentials ---
  #
  # Production's OAuth App expires tokens; the development registration is a
  # different app and may not. Both shapes reach this method and both have to
  # come out right, which is why these are two tests rather than one.

  test "from_omniauth captures the refresh token and expiry an expiring app sends" do
    auth = github_auth_hash(
      User.new(github_id: 13_579, login: "expiring-erin", access_token: "gho_fresh"),
      expiring: true, refresh_token: "ghr_fresh", expires_in: 28_800
    )

    user = User.from_omniauth(auth)

    assert_equal "gho_fresh", user.access_token
    assert_equal "ghr_fresh", user.refresh_token
    assert user.refreshable?
    assert_in_delta 28_800, user.access_token_expires_at - Time.current, 60
  end

  test "from_omniauth leaves a non-expiring app's user with nothing to refresh" do
    auth = github_auth_hash(
      User.new(github_id: 24_680, login: "forever-fran", access_token: "gho_forever"),
      expiring: false
    )

    user = User.from_omniauth(auth)

    assert_equal "gho_forever", user.access_token
    assert_nil user.refresh_token
    assert_nil user.access_token_expires_at
    assert_not user.refreshable?
    assert_not Github::Credentials.stale?(user)
  end

  # A sign-in is the authority on the credential. Keeping a refresh token from
  # a grant that has just been replaced would leave the three columns
  # describing two different grants.
  test "from_omniauth replaces a stored refresh token with what this sign-in returned" do
    existing = users(:prism_dev)
    existing.update!(refresh_token: "ghr_from_the_old_grant", access_token_expires_at: 1.hour.from_now)

    User.from_omniauth(github_auth_hash(existing, token: "gho_new", expiring: false))

    existing.reload
    assert_nil existing.refresh_token
    assert_nil existing.access_token_expires_at
  end

  test "refresh_token is encrypted at rest, exactly like the access token" do
    user = users(:prism_dev)
    user.update!(refresh_token: "ghr_very_secret")

    ciphertext = User.connection.select_value("SELECT refresh_token FROM users WHERE id = #{user.id}")

    assert_equal "ghr_very_secret", user.reload.refresh_token
    assert_no_match(/ghr_very_secret/, ciphertext.to_s)
  end

  # omniauth hands over an Integer of unix seconds; a hand-built hash might
  # use anything. None of it may raise on the sign-in path.
  test "from_omniauth reads an expiry in whatever form it arrives" do
    at = 3.hours.from_now

    [ at.to_i, at, at.iso8601 ].each do |value|
      user = User.from_omniauth(
        "uid" => "31337",
        "info" => { "nickname" => "clocky" },
        "credentials" => { "token" => "gho_x", "refresh_token" => "ghr_x", "expires_at" => value },
        "extra" => { "scope" => "repo" }
      )

      assert_in_delta at.to_i, user.access_token_expires_at.to_i, 1, "failed for #{value.class}"
    end
  end

  test "from_omniauth treats an unreadable expiry as no expiry rather than raising" do
    user = User.from_omniauth(
      "uid" => "31338",
      "info" => { "nickname" => "nonsense" },
      "credentials" => { "token" => "gho_x", "expires_at" => "not a time at all" },
      "extra" => { "scope" => "repo" }
    )

    assert_nil user.access_token_expires_at
  end

  test "from_omniauth matches on github_id, not login, so a rename updates in place" do
    existing = users(:prism_dev)
    auth = github_auth_hash(existing, token: "gho_rotated").tap do |hash|
      hash.info.nickname = "prism-dev-renamed"
      hash.info.name = "Renamed Dev"
    end

    assert_no_difference -> { User.count } do
      User.from_omniauth(auth)
    end

    existing.reload
    assert_equal "prism-dev-renamed", existing.login
    assert_equal "Renamed Dev", existing.name
    assert_equal "gho_rotated", existing.access_token
  end

  test "from_omniauth reads the granted scope from extra, not credentials" do
    user = User.from_omniauth(github_auth_hash(users(:prism_dev), scope: "public_repo,read:user"))

    assert_equal "public_repo,read:user", user.token_scopes
    assert_not user.can_write_reviews?
  end

  test "from_omniauth accepts a plain nested hash" do
    user = User.from_omniauth(
      "uid" => "9090",
      "info" => { "nickname" => "plainhash", "name" => nil, "image" => nil },
      "credentials" => { "token" => "gho_plain" },
      "extra" => { "scope" => "repo" }
    )

    assert_equal 9090, user.github_id
    assert_equal "plainhash", user.login
    assert_equal "gho_plain", user.access_token
  end

  test "token scopes are normalized from whatever separator GitHub used" do
    user = User.new(login: "x", github_id: 1, token_scopes: " repo , read:org  read:user , repo ")

    assert_equal "repo,read:org,read:user", user.token_scopes
    assert_equal %w[repo read:org read:user], user.scopes
  end

  test "can_write_reviews? requires the repo scope" do
    assert users(:prism_dev).can_write_reviews?
    assert_not users(:read_only).can_write_reviews?
  end

  # Everything that made up the grant goes together. A refresh token left
  # beside a cleared access token would be spent on the next request and
  # refused all over again, which is a loop rather than a sign-out.
  test "revoke_token! clears the whole grant, refresh token included" do
    user = users(:prism_dev)
    user.update!(refresh_token: "ghr_dead", access_token_expires_at: 1.hour.from_now)

    user.revoke_token!

    user.reload
    assert_nil user.access_token
    assert_nil user.refresh_token
    assert_nil user.access_token_expires_at
    assert_nil user.token_scopes
    assert_not user.token?
    assert_not user.refreshable?
    assert_not user.can_write_reviews?
  end

  test "refreshable? is false for a user who has never had an expiring token" do
    assert_not users(:prism_dev).refreshable?
  end

  test "display_name falls back to the login" do
    assert_equal "Prism Dev", users(:prism_dev).display_name
    assert_equal "nameless", User.new(login: "nameless").display_name
  end

  test "html_url is derived from the login" do
    assert_equal "https://github.com/prism-dev", users(:prism_dev).html_url
  end

  test "github_id must be unique" do
    duplicate = User.new(github_id: users(:prism_dev).github_id, login: "impostor")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:github_id], "has already been taken"
  end

  test "login is required" do
    assert_not User.new(github_id: 5).valid?
  end
end
