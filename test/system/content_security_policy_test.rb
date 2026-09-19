# frozen_string_literal: true

require "application_system_test_case"

# The policy is enforced, not report-only, so a directive that is too tight
# doesn't raise — the blocked thing just never happens and the page looks
# almost right. These tests walk every screen in real Chromium and fail on the
# console messages that are the only evidence.
class ContentSecurityPolicyTest < ApplicationSystemTestCase
  OWNER = "acme"
  REPO  = "docs-site"
  NUMBER = 42

  setup do
    @user = users(:prism_dev)
    stub_github_get("/user/repos", fixture: :repos)
    stub_github_get("/repos/#{OWNER}/#{REPO}", fixture: :repo)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls", fixture: :pulls)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/files", fixture: :pull_files)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", fixture: :reviews)
    stub_github_markdown(fixture: "markdown.html")
  end

  test "signing in and browsing every screen triggers no CSP violation" do
    mock_github_auth(@user)

    visit sign_in_path
    assert_selector "[data-testid=sign-in]"

    click_on "Continue with GitHub"
    assert_selector "[data-testid=repo-list]"

    visit repo_pulls_path(owner: OWNER, repo: REPO)
    assert_selector "[data-testid=pull-request-list]"

    visit repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)
    assert_selector "[data-testid=markdown-files]"

    assert_no_csp_violations
  end

  test "the JavaScript the policy has to allow actually runs" do
    sign_in_as(@user)
    visit repos_path

    # If script-src blocked the importmap, Stimulus would never connect and
    # both of these would silently do nothing — which is exactly the failure a
    # "page rendered" assertion misses.
    fill_in "repo-filter", with: "docs-site"
    assert_selector "[data-testid=repo-row]", count: 1

    find("[data-testid=account-menu] summary").click
    assert_text @user.login

    assert_no_csp_violations
  end

  test "a GitHub label keeps its own colour, which needs style-src-attr" do
    sign_in_as(@user)
    visit repo_pulls_path(owner: OWNER, repo: REPO)

    # Blocked inline styles leave the element rendered but unstyled, so assert
    # the computed colour rather than the attribute.
    background = page.evaluate_script(<<~JS)
      getComputedStyle(document.querySelector('[data-testid=labels] .label-pill')).backgroundColor
    JS

    assert_equal "rgb(0, 117, 202)", background, "the label pill lost its GitHub colour"
    assert_no_csp_violations
  end

  test "the web fonts load, which needs font-src and style-src" do
    sign_in_as(@user)
    visit repos_path

    loaded = page.evaluate_script(<<~JS)
      (function () {
        return Array.from(document.fonts).some(function (f) {
          return f.family.indexOf("Space Grotesk") !== -1;
        });
      })()
    JS

    assert loaded, "Space Grotesk never reached the page — check font-src and style-src"
    assert_no_csp_violations
  end
end
