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

  test "revoke_token! clears the token and its scopes" do
    user = users(:prism_dev)
    user.revoke_token!

    assert_nil user.reload.access_token
    assert_nil user.token_scopes
    assert_not user.token?
    assert_not user.can_write_reviews?
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
