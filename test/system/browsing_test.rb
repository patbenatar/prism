# frozen_string_literal: true

require "application_system_test_case"

# The browsing path end to end: sign in with GitHub, pick a repository, pick a
# pull request, and see the Markdown files Prism can render.
class BrowsingTest < ApplicationSystemTestCase
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

  test "signing in and browsing through to a pull request's Markdown files" do
    # Arm OmniAuth's mock before the browser touches /auth/github — without it
    # the real GitHub sign-in page loads, since the browser's requests don't go
    # through WebMock.
    mock_github_auth(@user)

    visit root_path

    # Signed out, the only thing on offer is GitHub.
    assert_text "Review a pull request's Markdown"
    click_on "Continue with GitHub"

    # Repositories.
    assert_selector "[data-testid=repo-list]"
    assert_text "docs-site"
    assert_selector "[data-testid=top-bar]"

    # Pull requests for that repository.
    click_on "docs-site", match: :first
    assert_selector "[data-testid=pull-request-list]"
    assert_text "Rewrite the getting-started guide"

    # The overview, with the Markdown files broken out.
    click_on "Rewrite the getting-started guide"
    assert_selector "[data-testid=pr-state]", text: "Open"
    assert_selector "[data-testid=markdown-files]"
    assert_selector "[data-testid=markdown-file]", minimum: 1

    # And those files anchor into the Markdown tab rather than out to GitHub.
    markdown_path = github_fixture(:pull_files)
      .map { |file| file["filename"] }
      .find { |path| path.match?(/\.md\z/i) }
    target = repo_pull_markdown_path(owner: OWNER, repo: REPO, number: NUMBER,
                                     anchor: Review::Page.file_key(markdown_path))

    assert_selector "a[href='#{target}']"
  end

  test "the repository filter narrows the list without a round trip" do
    sign_in_as(@user)
    visit repos_path

    assert_selector "[data-testid=repo-row]", minimum: 2

    fill_in "repo-filter", with: "docs-site"

    assert_selector "[data-testid=repo-row]", count: 1
    assert_text "docs-site"
  end

  test "the filter explains itself when nothing matches" do
    sign_in_as(@user)
    visit repos_path

    fill_in "repo-filter", with: "zzzznothing"

    assert_selector "[data-testid=filter-empty]", visible: true
    assert_text "No repository matches that"
  end

  test "the account menu opens and signs you out" do
    sign_in_as(@user)
    visit repos_path

    find("[data-testid=account-menu] summary").click
    assert_text @user.login

    click_on "Sign out"

    assert_text "Review a pull request's Markdown"
    assert_current_path sign_in_path
  end

  test "nothing overflows horizontally on a phone" do
    sign_in_as(@user)
    visit repos_path

    page.driver.browser.manage.window.resize_to(390, 844)
    visit repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)
    assert_selector "[data-testid=markdown-files]"

    overflow = page.evaluate_script(
      "document.documentElement.scrollWidth - document.documentElement.clientWidth"
    )
    assert_operator overflow, :<=, 1, "the page scrolls sideways at 390px"
  end
end
