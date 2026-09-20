# frozen_string_literal: true

require "application_system_test_case"

# Watching a repository from the repository's own page — the screen someone
# is actually on when they decide they want it.
#
# Driven through the browser because the whole point of the control is that
# it flips in place: a Turbo Stream aimed at an id that isn't there, or a
# failure that redirects away instead of explaining itself where it happened,
# both look fine in an integration test.
class RepoWatchSystemTest < ApplicationSystemTestCase
  OWNER = "acme"
  REPO  = "docs-site"
  CALLBACK = "https://prism.test/webhooks/github"

  setup do
    @user = users(:prism_dev)
    ENV["PRISM_PUBLIC_URL"] = "https://prism.test"
    # Signing in lands on /repos before any test navigates anywhere.
    stub_github_get("/user/repos", fixture: :repos)
    sign_in_as @user
  end

  teardown { ENV.delete("PRISM_PUBLIC_URL") }

  test "watching a repository from its pull request list flips the control in place" do
    stub_pulls("acme", "new-docs")
    stub_github_post("/repos/acme/new-docs/hooks", body: hook_payload(id: 9001))

    visit repo_pulls_path(owner: "acme", repo: "new-docs")

    # The consent is on the screen before the button, not after it: Prism is
    # about to write into pull request descriptions under this name.
    within "[data-testid=repo-watch]" do
      assert_text "as @prism-dev"
      assert_text "admin access"
    end

    mark_page
    click_on "Watch repository"

    within "[data-testid=repo-watch]" do
      assert_text "Active"
      assert_selector "[data-testid=repo-unwatch-button]"
      assert_no_selector "[data-testid=repo-watch-button]"
    end

    assert page_never_reloaded?, "the control should have been streamed in, not the whole page"
    assert_equal CALLBACK, github_request_body(:post, "/repos/acme/new-docs/hooks").dig("config", "url")
    assert_no_csp_violations
  end

  test "a repository already being watched says so on arrival, and can be stopped from here" do
    stub_pulls
    stub_github_delete("/repos/#{OWNER}/#{REPO}/hooks/555")

    visit repo_pulls_path(owner: OWNER, repo: REPO)

    within("[data-testid=repo-watch]") { assert_text "Active" }

    mark_page
    accept_confirm { click_on "Stop watching" }

    within "[data-testid=repo-watch]" do
      assert_selector "[data-testid=repo-watch-button]"
      assert_no_text "Active"
    end

    assert page_never_reloaded?
    assert_requested :delete, "https://api.github.com/repos/#{OWNER}/#{REPO}/hooks/555"
    assert_nil WebhookSubscription.find_by(name: REPO)
  end

  test "watching a repository this account does not administer explains itself next to the button" do
    stub_pulls("acme", "new-docs")
    stub_github_error(:post, "/repos/acme/new-docs/hooks", status: 404, message: "Not Found")

    visit repo_pulls_path(owner: "acme", repo: "new-docs")
    click_on "Watch repository"

    within "[data-testid=repo-watch]" do
      assert_selector "[data-testid=repo-watch-error]", text: "You need admin access to acme/new-docs"
      # Still offering the thing that failed — access can be granted and the
      # button tried again.
      assert_selector "[data-testid=repo-watch-button]"
    end

    assert_no_selector "[data-testid=flash]"
    assert_no_csp_violations
  end

  test "watching with no public URL configured says which variable is missing" do
    ENV.delete("PRISM_PUBLIC_URL")
    stub_pulls("acme", "new-docs")

    visit repo_pulls_path(owner: "acme", repo: "new-docs")
    click_on "Watch repository"

    within "[data-testid=repo-watch]" do
      assert_selector "[data-testid=repo-watch-error]", text: "PRISM_PUBLIC_URL"
      assert_selector "[data-testid=repo-watch-button]"
    end

    assert_not_requested :post, /api\.github\.com/
  end

  test "a moved tunnel is visible here too, and re-registering fixes it in place" do
    ENV["PRISM_PUBLIC_URL"] = "https://a-new-tunnel.ngrok-free.app"
    stub_pulls
    stub_github_patch("/repos/#{OWNER}/#{REPO}/hooks/555",
                      body: hook_payload(id: 555).merge(
                        "config" => { "url" => "https://a-new-tunnel.ngrok-free.app/webhooks/github" }
                      ))

    visit repo_pulls_path(owner: OWNER, repo: REPO)

    within "[data-testid=repo-watch]" do
      assert_selector "[data-testid=subscription-stale]", text: "Wrong address"
      assert_text "Nothing is arriving"

      click_on "Re-register"

      assert_text "Active"
      assert_no_selector "[data-testid=subscription-stale]"
    end
  end

  test "it looks right at 1440 and at 390, watched and not" do
    stub_pulls
    stub_pulls("acme", "new-docs")

    [ [ 1440, 900 ], [ 390, 844 ] ].each do |width, height|
      resize_window(width, height)

      visit repo_pulls_path(owner: "acme", repo: "new-docs")
      assert_selector "[data-testid=repo-watch-button]"
      assert_no_horizontal_overflow
      take_screenshot

      visit repo_pulls_path(owner: OWNER, repo: REPO)
      assert_selector "[data-testid=repo-unwatch-button]"
      assert_no_horizontal_overflow
      take_screenshot
    end
  end

  # Tokens only, so dark mode is supposed to come for free —
  # DarkModeTest#"no screen paints a pale panel on the dark canvas" already
  # sweeps this screen for hardcoded colours. This is the picture of it, plus
  # the two states that sweep never reaches: the inline failure and the
  # wrong-address one.
  test "the control reads in dark mode, watched, unwatched and failing" do
    stub_pulls
    stub_pulls("acme", "new-docs")
    stub_github_error(:post, "/repos/acme/new-docs/hooks", status: 404, message: "Not Found")

    with_color_scheme(:dark) do
      visit repo_pulls_path(owner: OWNER, repo: REPO)
      assert_selector "[data-testid=repo-unwatch-button]"
      take_screenshot

      visit repo_pulls_path(owner: "acme", repo: "new-docs")
      click_on "Watch repository"
      assert_selector "[data-testid=repo-watch-error]"
      take_screenshot
    end
  end

  private

  def assert_no_horizontal_overflow
    overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")

    assert_operator overflow, :<=, 1, "the page scrolls sideways by #{overflow}px"
  end

  # Turbo replaces one element; a full navigation would throw this away.
  def mark_page = page.execute_script("window.__prismStayed = true")

  def page_never_reloaded? = page.evaluate_script("window.__prismStayed === true")

  def stub_pulls(owner = OWNER, repo = REPO)
    stub_github_get("/repos/#{owner}/#{repo}", body: repo_payload(owner, repo))
    stub_github_get("/repos/#{owner}/#{repo}/pulls", body: [])
  end

  def repo_payload(owner, name, id: 555_001)
    { "id" => id, "name" => name, "full_name" => "#{owner}/#{name}", "private" => false,
      "description" => "Product documentation, written in Markdown.", "default_branch" => "main",
      "pushed_at" => "2026-09-18T16:30:00Z", "open_issues_count" => 0,
      "html_url" => "https://github.com/#{owner}/#{name}",
      "owner" => { "login" => owner, "avatar_url" => "https://example.test/a.png", "type" => "User" } }
  end

  def hook_payload(id:)
    { "id" => id, "type" => "Repository", "name" => "web", "active" => true,
      "events" => [ "pull_request" ],
      "config" => { "url" => CALLBACK, "content_type" => "json", "insecure_ssl" => "0" } }
  end
end
