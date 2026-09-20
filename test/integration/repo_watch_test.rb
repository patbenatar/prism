# frozen_string_literal: true

require "test_helper"

# Watching a repository from the repository's own page.
#
# The same two controller actions /subscriptions posts to, reached with
# `from=repo`, which is the only difference: the answer is the control itself
# rather than a redirect to a screen nobody asked for. So what is asserted
# here is the answer — what comes back, what it says, and where the HTML
# fallback lands — not the registrar, which
# test/integration/webhook_subscriptions_test.rb already covers end to end.
class RepoWatchTest < ActionDispatch::IntegrationTest
  OWNER = "acme"
  REPO  = "docs-site"
  CALLBACK = "https://prism.test/webhooks/github"

  setup do
    @user = users(:prism_dev)
    ENV["PRISM_PUBLIC_URL"] = "https://prism.test"
  end

  teardown { ENV.delete("PRISM_PUBLIC_URL") }

  # ── The control on the page ────────────────────────────────────────────

  test "a repository nobody is watching offers to watch it, and says what that does" do
    sign_in_and_stub_pulls("acme", "new-docs")

    get repo_pulls_path(owner: "acme", repo: "new-docs")

    assert_response :success
    assert_select "[data-testid=repo-watch-button]"
    assert_select "[data-testid=repo-watch]", /as @#{@user.login}/
    assert_select "[data-testid=repo-watch]", /admin access/
  end

  test "a watched repository says so and offers to stop" do
    sign_in_and_stub_pulls

    get repo_pulls_path(owner: OWNER, repo: REPO)

    assert_select "[data-testid=repo-watch] .pill-added", "Active"
    assert_select "[data-testid=repo-unwatch-button]"
    assert_select "[data-testid=repo-watch-button]", false
  end

  test "a broken subscription shows the same words the subscriptions screen uses" do
    webhook_subscriptions(:docs_site).mark_broken!("GitHub rejected the token")
    sign_in_and_stub_pulls

    get repo_pulls_path(owner: OWNER, repo: REPO)

    assert_select "[data-testid=repo-watch] [data-testid=subscription-broken]", "Not working"
    assert_select "[data-testid=broken-reason]", /GitHub rejected the token/
  end

  test "a moved public URL shows the wrong-address state and offers to re-register" do
    ENV["PRISM_PUBLIC_URL"] = "https://a-new-tunnel.ngrok-free.app"
    sign_in_and_stub_pulls

    get repo_pulls_path(owner: OWNER, repo: REPO)

    assert_select "[data-testid=repo-watch] [data-testid=subscription-stale]", "Wrong address"
    assert_select "[data-testid=repo-re-register-button]"
  end

  test "one person's subscription is not another's watch state" do
    sign_in_as users(:octocat)
    stub_pulls_endpoints

    get repo_pulls_path(owner: OWNER, repo: REPO)

    # prism_dev watches acme/docs-site; octocat does not, and must not be told.
    assert_select "[data-testid=repo-watch-button]"
    assert_select "[data-testid=repo-unwatch-button]", false
  end

  # ── Watching ───────────────────────────────────────────────────────────

  test "watching from the repository page answers with the control, now watching" do
    sign_in_as @user
    stub_repo("acme", "new-docs")
    stub_github_post("/repos/acme/new-docs/hooks", body: hook_payload(id: 9001))

    assert_difference "WebhookSubscription.count", 1 do
      post webhook_subscriptions_path,
           params: { full_name: "acme/new-docs", from: "repo" }, as: :turbo_stream
    end

    assert_response :success
    assert_turbo_stream_replaces "repo-watch"
    assert_match "repo-unwatch-button", response.body
    assert_match "Stop watching", response.body
    assert_equal "acme", WebhookSubscription.order(:id).last.owner
  end

  test "watching without Turbo redirects back to the repository, not to /subscriptions" do
    sign_in_as @user
    stub_repo("acme", "new-docs")
    stub_github_post("/repos/acme/new-docs/hooks", body: hook_payload(id: 9001))

    post webhook_subscriptions_path, params: { full_name: "acme/new-docs", from: "repo" }

    assert_redirected_to repo_pulls_path(owner: "acme", repo: "new-docs")
    assert_match(/as @#{@user.login}/, flash[:notice])
  end

  test "a repository already being watched says so in the control" do
    sign_in_as @user
    stub_repo(OWNER, REPO, id: 900_001)

    assert_no_difference "WebhookSubscription.count" do
      post webhook_subscriptions_path,
           params: { full_name: "#{OWNER}/#{REPO}", from: "repo" }, as: :turbo_stream
    end

    assert_response :unprocessable_entity
    assert_select_turbo_error(/already subscribed/)
    # The existing subscription is untouched, so the control still offers to stop.
    assert_match "repo-unwatch-button", response.body
    assert_github_not_requested :post, "/repos/#{OWNER}/#{REPO}/hooks"
  end

  # GitHub hides the hooks endpoints from non-admins behind a 404, so this is
  # the failure most people meet first.
  test "no admin access explains itself next to the button" do
    sign_in_as @user
    stub_repo("acme", "new-docs")
    stub_github_error(:post, "/repos/acme/new-docs/hooks", status: 404, message: "Not Found")

    assert_no_difference "WebhookSubscription.count" do
      post webhook_subscriptions_path,
           params: { full_name: "acme/new-docs", from: "repo" }, as: :turbo_stream
    end

    assert_response :unprocessable_entity
    assert_select_turbo_error(/admin access to acme\/new-docs/)
    # Still offering the thing that failed, so it can be retried once access is granted.
    assert_match "repo-watch-button", response.body
  end

  test "no public URL explains itself next to the button and never calls GitHub" do
    ENV.delete("PRISM_PUBLIC_URL")
    sign_in_as @user

    assert_no_difference "WebhookSubscription.count" do
      post webhook_subscriptions_path,
           params: { full_name: "acme/new-docs", from: "repo" }, as: :turbo_stream
    end

    assert_response :unprocessable_entity
    assert_select_turbo_error(/PRISM_PUBLIC_URL/)
    assert_not_requested :any, /api\.github\.com/
  end

  # ── Unwatching, and re-registering ─────────────────────────────────────

  test "unwatching answers with the control, now offering to watch again" do
    sign_in_as @user
    stub_github_delete("/repos/#{OWNER}/#{REPO}/hooks/555")

    assert_difference "WebhookSubscription.count", -1 do
      delete webhook_subscription_path(webhook_subscriptions(:docs_site)),
             params: { from: "repo" }, as: :turbo_stream
    end

    assert_response :success
    assert_turbo_stream_replaces "repo-watch"
    assert_match "repo-watch-button", response.body
    assert_github_requested :delete, "/repos/#{OWNER}/#{REPO}/hooks/555"
  end

  test "a hook GitHub would not delete is reported in the control, not swallowed" do
    sign_in_as @user
    stub_github_error(:delete, "/repos/#{OWNER}/#{REPO}/hooks/555", status: 500, message: "boom")

    delete webhook_subscription_path(webhook_subscriptions(:docs_site)),
           params: { from: "repo" }, as: :turbo_stream

    assert_response :unprocessable_entity
    assert_select_turbo_error(/Settings → Webhooks/)
  end

  test "re-registering from the repository page fixes the address in place" do
    ENV["PRISM_PUBLIC_URL"] = "https://a-new-tunnel.ngrok-free.app"
    stub_github_patch("/repos/#{OWNER}/#{REPO}/hooks/555", body: hook_payload(id: 555))

    sign_in_as @user
    patch webhook_subscription_path(webhook_subscriptions(:docs_site)),
          params: { from: "repo" }, as: :turbo_stream

    assert_response :success
    assert_turbo_stream_replaces "repo-watch"
    assert_no_match "subscription-stale", response.body
    assert_equal "https://a-new-tunnel.ngrok-free.app/webhooks/github",
                 webhook_subscriptions(:docs_site).reload.callback_url
  end

  # ── The other screen is unchanged ──────────────────────────────────────

  test "without from=repo the subscriptions screen still redirects to itself" do
    sign_in_as @user
    stub_repo("acme", "new-docs")
    stub_github_post("/repos/acme/new-docs/hooks", body: hook_payload(id: 9001))

    post webhook_subscriptions_path, params: { full_name: "acme/new-docs" }, as: :turbo_stream

    assert_redirected_to webhook_subscriptions_path
  end

  private

  def assert_turbo_stream_replaces(target)
    assert_match "text/vnd.turbo-stream.html", response.media_type
    assert_match(/<turbo-stream action="replace" target="#{target}">/, response.body)
  end

  # The stream's payload is escaped HTML inside a <template>, so the error is
  # asserted on the unescaped text rather than with assert_select.
  def assert_select_turbo_error(pattern)
    assert_match "repo-watch-error", response.body
    assert_match pattern, CGI.unescapeHTML(response.body)
  end

  def sign_in_and_stub_pulls(owner = OWNER, repo = REPO)
    sign_in_as @user
    stub_pulls_endpoints(owner, repo)
  end

  def stub_pulls_endpoints(owner = OWNER, repo = REPO)
    stub_repo(owner, repo)
    stub_github_get("/repos/#{owner}/#{repo}/pulls", body: [])
  end

  def stub_repo(owner, name, id: 555_001)
    stub_github_get("/repos/#{owner}/#{name}", body: {
      "id" => id, "name" => name, "full_name" => "#{owner}/#{name}", "private" => false,
      "description" => nil, "default_branch" => "main", "pushed_at" => "2026-09-18T16:30:00Z",
      "open_issues_count" => 0, "html_url" => "https://github.com/#{owner}/#{name}",
      "owner" => { "login" => owner, "avatar_url" => "https://example.test/a.png", "type" => "User" }
    })
  end

  def hook_payload(id:)
    { "id" => id, "type" => "Repository", "name" => "web", "active" => true,
      "events" => [ "pull_request" ],
      "config" => { "url" => CALLBACK, "content_type" => "json", "insecure_ssl" => "0" } }
  end
end
