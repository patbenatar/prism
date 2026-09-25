# frozen_string_literal: true

require "application_system_test_case"

# The session cookie has to actually survive a browser restart, not just carry
# an `expires` attribute that nothing ever checks. A real browser drops every
# cookie that lacks one and keeps the rest; this simulates exactly that by
# wiping the browser's cookie jar and restoring only the captured session
# cookie, then confirming that alone is enough to stay signed in.
class SessionPersistenceTest < ApplicationSystemTestCase
  setup do
    @user = users(:prism_dev)
    stub_github_get("/user/repos", fixture: :repos)
  end

  test "the session cookie is persistent, and surviving on its own is enough to stay signed in" do
    sign_in_as(@user)
    assert_selector "[data-testid=repo-list]"

    session_cookie = page.driver.browser.manage.all_cookies.find { |c| c[:name] == "_prism_app_session" }
    assert session_cookie, "expected a _prism_app_session cookie"
    assert session_cookie[:expires], "a session-only cookie (no expiry) would not survive a browser restart"

    # Wipe everything, as an actual browser restart would to any cookie
    # without a persistent expiry.
    page.driver.browser.manage.delete_all_cookies
    visit sign_in_path
    assert_selector "[data-testid=sign-in]", wait: 5

    # Restore only the one cookie that would have survived a real restart —
    # no other browser state — and confirm it alone is enough.
    page.driver.browser.manage.add_cookie(
      name: session_cookie[:name],
      value: session_cookie[:value],
      path: session_cookie[:path],
      domain: session_cookie[:domain],
      expires: session_cookie[:expires],
      secure: session_cookie[:secure]
    )

    visit repos_path

    assert_selector "[data-testid=repo-list]"
    assert_no_current_path sign_in_path
  end

  # The other half of "staying signed in", and the half that was actually
  # broken. Prism's OAuth App hands out an eight-hour GitHub token, so a
  # reviewer who signed in before lunch used to find every page failing by
  # mid-afternoon while the cookie above sat there perfectly valid. Driven
  # through the browser because that is the only way to prove the person sees
  # a working page rather than an exception the integration tests translate.
  test "an expired GitHub token is renewed behind the scenes and the reviewer never notices" do
    sign_in_as(@user, token: "gho_before_lunch", expiring: true, refresh_token: "ghr_before_lunch")
    assert_selector "[data-testid=repo-list]"

    travel_to 9.hours.from_now do
      stub_github_token_refresh(access_token: "gho_after_lunch", refresh_token: "ghr_after_lunch")

      visit repos_path

      assert_selector "[data-testid=repo-list]", wait: 5
      assert_no_current_path sign_in_path
      assert_no_text "Sign in with GitHub to continue"
    end

    @user.reload
    assert_equal "gho_after_lunch", @user.access_token
    assert_equal "ghr_after_lunch", @user.refresh_token, "the spent refresh token must not survive"
  end
end
