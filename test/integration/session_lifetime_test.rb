# frozen_string_literal: true

require "test_helper"

# The session cookie's lifetime: a real expiry (30 days) rather than "until
# the browser closes", and sliding renewal so active use keeps it alive past
# that. See PLAN.md round 2 (W2) for the mechanism this exercises.
class SessionLifetimeTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:prism_dev)
    stub_github_get("/user/repos", fixture: :repos)
  end

  # Rack writes the cookie's expiry as `Time.now + expire_after`: a fixed number
  # of seconds. `30.days.from_now` is calendar arithmetic in the app's time
  # zone, so the two disagree by exactly an hour whenever the window straddles a
  # daylight saving change. That is why this test began failing on its own in
  # late September with no code change — `now + 10.days + 30.days` had started
  # landing past the November transition. Compare seconds to seconds.
  def expected_expiry = Time.now.to_i + 30.days.to_i

  def session_cookie_expiry(response)
    header = Array(response.headers["Set-Cookie"]).join("\n")
    line = header.lines.find { |l| l.start_with?("_prism_app_session=") }
    return nil unless line

    match = line.match(/expires=([^;]+)/i)
    match && Time.parse(match[1])
  end

  test "signing in sets a session cookie with a real expiry, not a browser-session-only cookie" do
    sign_in_as(@user)

    expiry = session_cookie_expiry(response)

    assert expiry, "expected the session cookie to carry an explicit expiry"
    assert_in_delta expected_expiry, expiry.to_i, 5, "expiry should be ~30 days out"
  end

  test "a later request slides the expiry forward instead of leaving it fixed" do
    sign_in_as(@user)
    first_expiry = session_cookie_expiry(response)

    travel 10.days do
      get repos_path
      second_expiry = session_cookie_expiry(response)

      assert second_expiry, "the cookie should still be resent with a fresh expiry"
      assert_operator second_expiry, :>, first_expiry,
                      "10 days of activity should have pushed the expiry forward, not left it where sign-in set it"
      assert_in_delta expected_expiry, second_expiry.to_i, 5
    end
  end

  test "with no activity at all, the cookie is not renewed past its original 30 days" do
    sign_in_as(@user)

    travel_to 31.days.from_now do
      get repos_path

      # The test's cookie jar drops a cookie once it is past its own
      # `expires`, exactly as a real browser would, so an expired cookie is
      # never sent back and the request lands signed out.
      assert_redirected_to sign_in_path
    end
  end

  test "activity within the window keeps the visitor signed in well past the original 30 days" do
    sign_in_as(@user)

    travel_to 20.days.from_now do
      get repos_path
      assert_response :success
    end

    travel_to 45.days.from_now do
      get repos_path
      assert_response :success, "the visit at +20 days should have slid the expiry out to +50 days"
    end
  end

  test "a revoked GitHub token still signs the user out on the next request" do
    sign_in_as(@user)
    WebMock.reset!
    stub_github_error(:get, "/user/repos", status: 401, message: "Bad credentials")

    get repos_path

    assert_redirected_to sign_in_path
    assert_nil session[:user_id]
    assert_nil @user.reload.access_token
  end

  # ── The GitHub side of the session ─────────────────────────────────────
  #
  # The cookie above was never the thing that broke. Prism's production OAuth
  # App issues an eight-hour access token, and what used to happen at hour
  # nine was that the cookie stayed perfectly valid while every GitHub call
  # behind it started failing — a signed-in person looking at an error page.

  test "signing in stores the refresh token and the expiry GitHub quoted" do
    sign_in_as(@user, expiring: true, refresh_token: "ghr_from_sign_in")

    @user.reload
    assert_equal "ghr_from_sign_in", @user.refresh_token
    assert @user.refreshable?
    assert_in_delta 8.hours.from_now, @user.access_token_expires_at, 60
  end

  test "browsing nine hours after signing in renews the token instead of ending the session" do
    sign_in_as(@user, token: "gho_first", expiring: true, refresh_token: "ghr_first")

    travel_to 9.hours.from_now do
      WebMock.reset!
      stub_github_token_refresh(access_token: "gho_second", refresh_token: "ghr_second")
      stub_github_get("/user/repos", fixture: :repos)

      get repos_path

      assert_response :success, "an expired GitHub token must not be the end of the session"
      assert_equal @user.id, session[:user_id]
    end

    @user.reload
    assert_equal "gho_second", @user.access_token
    assert_equal "ghr_second", @user.refresh_token
  end

  # The one case that still ends a session — and it has to, because there is
  # nothing left to renew with.
  test "a refresh token GitHub has finished with signs the user out" do
    sign_in_as(@user, expiring: true)

    travel_to 9.hours.from_now do
      WebMock.reset!
      stub_github_token_error("bad_refresh_token")

      get repos_path

      assert_redirected_to sign_in_path
      assert_nil session[:user_id]
    end

    @user.reload
    assert_nil @user.access_token
    assert_nil @user.refresh_token
  end

  # GitHub's token endpoint being unreachable is an outage, not a verdict.
  # Signing everyone out over it would be the old bug wearing a new hat.
  test "GitHub being unreachable while renewing does not sign anybody out" do
    sign_in_as(@user, expiring: true, refresh_token: "ghr_intact")

    travel_to 9.hours.from_now do
      WebMock.reset!
      stub_github_token_unavailable(status: 503)

      get repos_path

      assert_response :service_unavailable
      assert_equal @user.id, session[:user_id]
    end

    @user.reload
    assert @user.token?
    assert_equal "ghr_intact", @user.refresh_token
  end
end
