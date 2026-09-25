# frozen_string_literal: true

require "test_helper"

class Github::CredentialsTest < ActiveSupport::TestCase
  setup do
    @user = users(:prism_dev)
    @user.update!(access_token: "gho_old", refresh_token: "ghr_old",
                  access_token_expires_at: 8.hours.from_now)
  end

  # ----------------------------------------------- when nothing should happen ---

  test "a user with no refresh token is handed their stored token untouched" do
    @user.update!(refresh_token: nil, access_token_expires_at: nil)

    assert_equal "gho_old", Github::Credentials.token_for(@user)
    assert_no_token_refresh
  end

  # The row shape every user has until they sign in again after this ships.
  # It must behave exactly as it did before there was any refresh machinery.
  test "a pre-existing row with an expiry but no refresh token is never renewed" do
    @user.update!(refresh_token: nil, access_token_expires_at: 1.hour.ago)

    assert_equal "gho_old", Github::Credentials.token_for(@user)
    assert_no_token_refresh
  end

  test "a token with hours left is handed over without asking GitHub anything" do
    assert_equal "gho_old", Github::Credentials.token_for(@user)
    assert_no_token_refresh
  end

  # A token GitHub never told us expires — a non-expiring OAuth App — is never
  # stale on a clock, whatever else is stored beside it.
  test "a null expiry is not staleness" do
    @user.update!(access_token_expires_at: nil)

    assert_equal "gho_old", Github::Credentials.token_for(@user)
    assert_no_token_refresh
  end

  test "a token just outside the margin is left alone" do
    @user.update!(access_token_expires_at: Github::Credentials::REFRESH_MARGIN.from_now + 1.minute)

    assert_equal "gho_old", Github::Credentials.token_for(@user)
    assert_no_token_refresh
  end

  # ------------------------------------------------------------ renewing ---

  test "an expired token is renewed and the whole new pair is persisted" do
    @user.update!(access_token_expires_at: 1.minute.ago)
    stub_github_token_refresh(access_token: "gho_new", refresh_token: "ghr_new", expires_in: 28_800)

    assert_equal "gho_new", Github::Credentials.token_for(@user)

    @user.reload
    assert_equal "gho_new", @user.access_token
    assert_equal "ghr_new", @user.refresh_token
    assert_in_delta 28_800, @user.access_token_expires_at - Time.current, 60
  end

  # The margin is the whole defence against a token that was valid when we
  # looked and expired before the request landed.
  test "a token inside the margin is renewed before it expires" do
    @user.update!(access_token_expires_at: 1.minute.from_now)
    stub_github_token_refresh(access_token: "gho_new")

    assert_equal "gho_new", Github::Credentials.token_for(@user)
    assert_token_refreshed
  end

  test "the refresh sends the grant type, the refresh token and the app credentials" do
    @user.update!(access_token_expires_at: 1.minute.ago)
    stub_github_token_refresh

    Github::Credentials.token_for(@user)

    assert_requested(:post, GithubStubs::OAUTH_TOKEN_URL) do |request|
      params = Rack::Utils.parse_nested_query(request.body)
      params["grant_type"] == "refresh_token" &&
        params["refresh_token"] == "ghr_old" &&
        params["client_id"] == "test_client_id" &&
        params["client_secret"] == "test_client_secret"
    end
  end

  # The one place a refresh token can be lost without anybody noticing: GitHub
  # invalidates the one we spent, so keeping the old one would leave the row
  # holding a credential that is already dead.
  test "the spent refresh token is replaced by the rotated one" do
    @user.update!(access_token_expires_at: 1.minute.ago)
    stub_github_token_refresh(refresh_token: "ghr_rotated")

    Github::Credentials.token_for(@user)

    assert_equal "ghr_rotated", @user.reload.refresh_token
  end

  # Defensive: GitHub always rotates, but dropping the only refresh token we
  # have because a response omitted one would sign the user out for nothing.
  test "a response with no refresh token keeps the stored one" do
    @user.update!(access_token_expires_at: 1.minute.ago)
    stub_github_token_refresh(refresh_token: nil)

    Github::Credentials.token_for(@user)

    assert_equal "ghr_old", @user.reload.refresh_token
  end

  # What arrives if the OAuth App's expiry setting is switched off between one
  # refresh and the next: the new token simply never goes stale.
  test "a response with no expires_in records no expiry" do
    @user.update!(access_token_expires_at: 1.minute.ago)
    stub_github_token_refresh(expires_in: nil)

    Github::Credentials.token_for(@user)

    assert_nil @user.reload.access_token_expires_at
    assert_not Github::Credentials.stale?(@user)
  end

  test "a missing access token is itself staleness, so the pair is renewed" do
    @user.update!(access_token: nil, access_token_expires_at: nil)
    stub_github_token_refresh(access_token: "gho_new")

    assert_equal "gho_new", Github::Credentials.token_for(@user)
  end

  # ------------------------------------------------- refusal versus outage ---

  test "bad_refresh_token ends the grant and clears every part of it" do
    @user.update!(access_token_expires_at: 1.minute.ago)
    stub_github_token_error("bad_refresh_token")

    assert_raises(Github::Unauthorized) { Github::Credentials.token_for(@user) }

    @user.reload
    assert_nil @user.access_token
    assert_nil @user.refresh_token
    assert_nil @user.access_token_expires_at
    assert_nil @user.token_scopes
  end

  test "invalid_grant ends the grant too" do
    @user.update!(access_token_expires_at: 1.minute.ago)
    stub_github_token_error("invalid_grant")

    assert_raises(Github::Unauthorized) { Github::Credentials.token_for(@user) }
    assert_not @user.reload.token?
  end

  # The revoke happens inside the row lock's transaction. Returning the
  # rejection rather than raising through it is what stops the rollback
  # undoing it — and an undone revoke means the next request spends the dead
  # refresh token again, forever.
  test "the revoke survives the transaction the row lock opened" do
    @user.update!(access_token_expires_at: 1.minute.ago)
    stub_github_token_error("bad_refresh_token")

    assert_raises(Github::Unauthorized) { Github::Credentials.token_for(@user) }

    assert_nil User.find(@user.id).refresh_token
  end

  # Our mistake, not theirs. Signing every user out because a deploy shipped
  # the wrong secret would turn a rollback into a support incident.
  test "incorrect_client_credentials is an outage, not a sign-out" do
    @user.update!(access_token_expires_at: 1.minute.ago)
    stub_github_token_error("incorrect_client_credentials", description: "The client_id and/or client_secret passed are incorrect.")

    assert_raises(Github::Unavailable) { Github::Credentials.token_for(@user) }

    @user.reload
    assert_equal "gho_old", @user.access_token
    assert_equal "ghr_old", @user.refresh_token
  end

  test "a 5xx from the token endpoint is an outage and changes nothing" do
    @user.update!(access_token_expires_at: 1.minute.ago)
    stub_github_token_unavailable(status: 502)

    assert_raises(Github::Unavailable) { Github::Credentials.token_for(@user) }
    assert_equal "ghr_old", @user.reload.refresh_token
  end

  test "an HTML error page where JSON was expected is an outage" do
    @user.update!(access_token_expires_at: 1.minute.ago)
    stub_request(:post, GithubStubs::OAUTH_TOKEN_URL)
      .to_return(status: 200, body: "<html>unicorn</html>", headers: { "Content-Type" => "text/html" })

    assert_raises(Github::Unavailable) { Github::Credentials.token_for(@user) }
    assert_equal "ghr_old", @user.reload.refresh_token
  end

  test "a 200 carrying no access token is an outage rather than a silent nil" do
    @user.update!(access_token_expires_at: 1.minute.ago)
    stub_request(:post, GithubStubs::OAUTH_TOKEN_URL)
      .to_return(status: 200, body: { "token_type" => "bearer" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    assert_raises(Github::Unavailable) { Github::Credentials.token_for(@user) }
    assert_equal "gho_old", @user.reload.access_token
  end

  test "a connection failure is an outage" do
    @user.update!(access_token_expires_at: 1.minute.ago)
    stub_request(:post, GithubStubs::OAUTH_TOKEN_URL).to_raise(Errno::ECONNREFUSED)

    assert_raises(Github::Unavailable) { Github::Credentials.token_for(@user) }
    assert_equal "ghr_old", @user.reload.refresh_token
  end

  test "no OAuth app credentials means an outage, and GitHub is never asked" do
    @user.update!(access_token_expires_at: 1.minute.ago)

    without_oauth_app_credentials do
      assert_raises(Github::Unavailable) { Github::Credentials.token_for(@user) }
    end

    assert_no_token_refresh
    assert_equal "ghr_old", @user.reload.refresh_token
  end

  # ------------------------------------------------- losing the race ---

  # The single-threaded half of the concurrency story: whatever the caller
  # tried with, if the row already holds something else then somebody has
  # renewed since, and theirs is the token to use. Spending our copy of the
  # refresh token here is exactly the mistake that destroys a working
  # credential.
  test "a forced refresh whose token has already been replaced uses the replacement" do
    @user.update!(access_token: "gho_someone_elses_newer_token")

    assert_equal "gho_someone_elses_newer_token", Github::Credentials.refresh(@user, used: "gho_old")
    assert_no_token_refresh
  end

  test "a forced refresh does ask GitHub when the row still holds the token that failed" do
    stub_github_token_refresh(access_token: "gho_new")

    assert_equal "gho_new", Github::Credentials.refresh(@user, used: "gho_old")
    assert_token_refreshed
  end

  # Called with no `used`, there is nothing to compare against, so the only
  # safe reading is "renew".
  test "a forced refresh with no token to compare against renews" do
    stub_github_token_refresh(access_token: "gho_new")

    assert_equal "gho_new", Github::Credentials.refresh(@user)
    assert_token_refreshed
  end

  test "a forced refresh on a user with nothing to refresh with does nothing" do
    @user.update!(refresh_token: nil)

    assert_equal "gho_old", Github::Credentials.refresh(@user, used: "gho_old")
    assert_no_token_refresh
  end

  test "a nil user is handled rather than raising on the way to GitHub" do
    assert_nil Github::Credentials.token_for(nil)
    assert_no_token_refresh
  end
end

# Two threads, one user, one single-use refresh token.
#
# This is the failure the whole locking design exists for, and it cannot be
# reproduced inside a transaction: `SELECT … FOR UPDATE` only blocks a *second
# connection*, and transactional fixtures give every thread the same one. So
# this case pays for a real commit and cleans up after itself.
class Github::CredentialsConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @user = User.create!(github_id: 909_090, login: "race-condition-rita",
                         access_token: "gho_old", refresh_token: "ghr_single_use",
                         access_token_expires_at: 1.minute.ago,
                         token_scopes: "repo,read:org,read:user")
  end

  teardown do
    User.where(id: @user.id).delete_all
  end

  test "two simultaneous refreshes spend the refresh token once and agree on the answer" do
    entered = Queue.new
    release = Queue.new

    # The first request parks inside GitHub until the test lets it go, which
    # is how we guarantee the second caller arrives while the first still
    # holds the lock. If the lock were not there, the second caller would
    # reach the endpoint too and get the second response — a
    # `bad_refresh_token`, because the token it holds has already been spent.
    winner = lambda do |_request|
      entered << true
      release.pop
      { status: 200,
        body: { "access_token" => "gho_winner", "refresh_token" => "ghr_rotated",
                "expires_in" => 28_800, "token_type" => "bearer" }.to_json,
        headers: { "Content-Type" => "application/json" } }
    end

    loser = { status: 200,
              body: { "error" => "bad_refresh_token",
                      "error_description" => "The refresh token passed is incorrect or expired." }.to_json,
              headers: { "Content-Type" => "application/json" } }

    stub_request(:post, GithubStubs::OAUTH_TOKEN_URL).to_return(winner, loser)

    first = refresh_in_thread
    entered.pop                # the winner is inside GitHub, holding the lock

    second = refresh_in_thread
    sleep 0.25                 # long enough for the loser to block on the lock

    release << true

    assert_equal "gho_winner", first.value, "the thread that won the race should get the new token"
    assert_equal "gho_winner", second.value, "the thread that lost should read the winner's token, not spend a dead one"

    assert_requested(:post, GithubStubs::OAUTH_TOKEN_URL, times: 1)

    @user.reload
    assert_equal "gho_winner", @user.access_token
    assert_equal "ghr_rotated", @user.refresh_token
    assert @user.access_token_expires_at > 7.hours.from_now
  end

  # The same race inside a single request. Review::PullRequestPage fans the
  # per-file GitHub reads out over worker threads and gives each one its own
  # Github::Client built from **the same User object** — so if that reviewer's
  # token has just expired, every worker reaches Github::Credentials at once
  # holding one shared row. It has to come out with one exchange and one
  # answer, and the shared object has to survive being reloaded underneath
  # readers.
  test "workers sharing one user object refresh it once between them" do
    @user.update!(access_token: "gho_old", refresh_token: "ghr_single_use",
                  access_token_expires_at: 1.minute.ago)

    stub_request(:post, GithubStubs::OAUTH_TOKEN_URL).to_return(
      { status: 200,
        body: { "access_token" => "gho_winner", "refresh_token" => "ghr_rotated",
                "expires_in" => 28_800, "token_type" => "bearer" }.to_json,
        headers: { "Content-Type" => "application/json" } },
      { status: 200,
        body: { "error" => "bad_refresh_token" }.to_json,
        headers: { "Content-Type" => "application/json" } }
    )

    shared = User.find(@user.id)
    barrier = Queue.new

    workers = 4.times.map do
      Thread.new do
        barrier.pop
        Github::Credentials.token_for(shared)
      ensure
        ActiveRecord::Base.connection_handler.clear_active_connections!
      end
    end

    4.times { barrier << true }
    tokens = workers.map(&:value)

    assert_equal [ "gho_winner" ], tokens.uniq, "every worker must end up on the same token"
    assert_requested(:post, GithubStubs::OAUTH_TOKEN_URL, times: 1)
    assert_equal "ghr_rotated", @user.reload.refresh_token
  end

  private

  # A separate User instance per thread, because two processes would each have
  # loaded their own — and a shared object would hide the reload the lock does.
  def refresh_in_thread
    id = @user.id

    Thread.new do
      Github::Credentials.token_for(User.find(id))
    ensure
      ActiveRecord::Base.connection_handler.clear_active_connections!
    end
  end
end
