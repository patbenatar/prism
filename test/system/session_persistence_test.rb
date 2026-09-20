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
end
