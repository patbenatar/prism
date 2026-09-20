# frozen_string_literal: true

require "test_helper"

class WebhookSubscriptionsTest < ActionDispatch::IntegrationTest
  include WebhookHelpers

  CALLBACK = "https://prism.test/webhooks/github"

  setup do
    @user = users(:prism_dev)
    ENV["PRISM_PUBLIC_URL"] = "https://prism.test"
  end

  teardown { ENV.delete("PRISM_PUBLIC_URL") }

  # ── The screen ─────────────────────────────────────────────────────────

  test "requires a signed-in user" do
    get webhook_subscriptions_path

    assert_redirected_to sign_in_path
  end

  test "lists what Prism is watching and says whose account it acts as" do
    sign_in_as @user
    stub_github_get("/user/repos", fixture: "repos")

    get webhook_subscriptions_path

    assert_response :success
    assert_select "[data-testid=subscription-row]", 1
    assert_select "[data-testid=acting-as-notice]" do
      assert_match(/@#{@user.login}/, response.body)
    end
  end

  test "warns when there is no public URL to deliver to" do
    ENV.delete("PRISM_PUBLIC_URL")
    sign_in_as @user
    stub_github_get("/user/repos", fixture: "repos")

    get webhook_subscriptions_path

    assert_select "[data-testid=public-url-warning]"
  end

  test "still renders when GitHub will not list repositories" do
    sign_in_as @user
    stub_github_error(:get, "/user/repos", status: 403, message: "nope")

    get webhook_subscriptions_path

    assert_response :success
    assert_select "[data-testid=repo-input]"
  end

  test "one person cannot see another's subscriptions" do
    sign_in_as users(:octocat)
    stub_github_get("/user/repos", fixture: "repos")

    get webhook_subscriptions_path

    # Asserted on the rows rather than the page: the repository picker lists
    # everything this account can reach on GitHub, which is a different thing
    # from what Prism is watching for them.
    rows = css_select("[data-testid=subscription-row]")

    assert_equal 1, rows.size
    assert_includes rows.first.to_s, "hello-world"
    assert_not_includes rows.first.to_s, "docs-site"
  end

  # ── Subscribing ────────────────────────────────────────────────────────

  test "registers a pull_request hook with a generated secret" do
    sign_in_as @user
    stub_repo("acme", "new-docs")
    stub_github_post("/repos/acme/new-docs/hooks", body: hook_payload(id: 9001))

    assert_difference "WebhookSubscription.count", 1 do
      post webhook_subscriptions_path, params: { full_name: "acme/new-docs" }
    end

    assert_redirected_to webhook_subscriptions_path

    subscription = WebhookSubscription.order(:id).last
    body = github_request_body(:post, "/repos/acme/new-docs/hooks")

    assert_equal "web", body["name"]
    assert_equal [ "pull_request" ], body["events"]
    assert_equal CALLBACK, body.dig("config", "url")
    assert_equal "json", body.dig("config", "content_type")
    assert_equal "0", body.dig("config", "insecure_ssl")
    assert_equal subscription.secret, body.dig("config", "secret")
    assert_equal 9001, subscription.hook_id
    assert_equal @user, subscription.user
  end

  test "the flash says the edit will be made as this person" do
    sign_in_as @user
    stub_repo("acme", "new-docs")
    stub_github_post("/repos/acme/new-docs/hooks", body: hook_payload(id: 9001))

    post webhook_subscriptions_path, params: { full_name: "acme/new-docs" }

    assert_match(/as @#{@user.login}/, flash[:notice])
  end

  test "keeps GitHub's casing of the repository name" do
    sign_in_as @user
    stub_repo("Acme", "New-Docs")
    stub_github_post("/repos/Acme/New-Docs/hooks", body: hook_payload(id: 9002))

    post webhook_subscriptions_path, params: { full_name: "Acme/New-Docs" }

    assert_equal "Acme/New-Docs", WebhookSubscription.order(:id).last.full_name
  end

  # GitHub hides the hooks endpoints from non-admins behind a 404, so the
  # message has to cover both readings.
  test "explains that a 404 on the hooks endpoint probably means no admin access" do
    sign_in_as @user
    stub_repo("acme", "new-docs")
    stub_github_error(:post, "/repos/acme/new-docs/hooks", status: 404, message: "Not Found")

    assert_no_difference "WebhookSubscription.count" do
      post webhook_subscriptions_path, params: { full_name: "acme/new-docs" }
    end

    assert_match(/admin access/, flash[:alert])
  end

  test "leaves no subscription behind when the hook cannot be created" do
    sign_in_as @user
    stub_repo("acme", "new-docs")
    stub_github_error(:post, "/repos/acme/new-docs/hooks", status: 404, message: "Not Found")

    post webhook_subscriptions_path, params: { full_name: "acme/new-docs" }

    assert_nil WebhookSubscription.find_by(name: "new-docs"),
               "a subscription with no hook would look live and never receive anything"
  end

  # The secret is write-only on GitHub's side, so the only way to adopt an
  # existing hook is to overwrite its config with a secret we can verify with.
  test "adopts an existing hook that already points at us, with a new secret" do
    sign_in_as @user
    stub_repo("acme", "new-docs")
    stub_github_error(:post, "/repos/acme/new-docs/hooks", status: 422,
                                                           message: "Validation Failed: Hook already exists on this repository")
    stub_github_get("/repos/acme/new-docs/hooks", body: [ hook_payload(id: 7777) ])
    stub_github_patch("/repos/acme/new-docs/hooks/7777", body: hook_payload(id: 7777))

    assert_difference "WebhookSubscription.count", 1 do
      post webhook_subscriptions_path, params: { full_name: "acme/new-docs" }
    end

    subscription = WebhookSubscription.order(:id).last
    body = github_request_body(:patch, "/repos/acme/new-docs/hooks/7777")

    assert_equal 7777, subscription.hook_id
    assert_equal subscription.secret, body.dig("config", "secret")
  end

  test "surfaces a 422 that is not an existing hook" do
    sign_in_as @user
    stub_repo("acme", "new-docs")
    stub_github_error(:post, "/repos/acme/new-docs/hooks", status: 422, message: "Validation Failed: bad config")
    stub_github_get("/repos/acme/new-docs/hooks", body: [])

    post webhook_subscriptions_path, params: { full_name: "acme/new-docs" }

    assert_match(/GitHub refused the webhook/, flash[:alert])
  end

  test "says so when the repository is invisible" do
    sign_in_as @user
    stub_github_error(:get, "/repos/acme/ghost", status: 404, message: "Not Found")

    post webhook_subscriptions_path, params: { full_name: "acme/ghost" }

    assert_match(/doesn't exist, or your GitHub account can't see it/, flash[:alert])
  end

  test "refuses to subscribe with no public URL to deliver to" do
    ENV.delete("PRISM_PUBLIC_URL")
    sign_in_as @user

    assert_no_difference "WebhookSubscription.count" do
      post webhook_subscriptions_path, params: { full_name: "acme/new-docs" }
    end

    assert_match(/PRISM_PUBLIC_URL/, flash[:alert])
    assert_not_requested :any, /api\.github\.com/
  end

  test "refuses a repository that is already subscribed" do
    sign_in_as @user
    stub_repo("acme", "docs-site", id: 900_001)

    assert_no_difference "WebhookSubscription.count" do
      post webhook_subscriptions_path, params: { full_name: "acme/docs-site" }
    end

    assert_match(/already subscribed/, flash[:alert])
  end

  test "rejects a malformed repository name without calling GitHub" do
    sign_in_as @user

    post webhook_subscriptions_path, params: { full_name: "not-a-repo" }

    assert_match(/Pick a repository/, flash[:alert])
    assert_not_requested :any, /api\.github\.com/
  end

  # ── A callback that has moved ──────────────────────────────────────────

  # The failure this state exists to make visible is silent: GitHub keeps
  # POSTing to a hostname nothing answers on, and the request never reaches
  # Prism, so no log here has anything in it.
  test "a subscription whose callback has moved says so and offers to re-register" do
    ENV["PRISM_PUBLIC_URL"] = "https://a-new-tunnel.ngrok-free.app"
    sign_in_as @user
    stub_github_get("/user/repos", fixture: "repos")

    get webhook_subscriptions_path

    assert_select "[data-testid=subscription-stale]", text: "Wrong address"
    assert_select "[data-testid=stale-reason]" do |elements|
      assert_match "https://prism.test/webhooks/github", elements.first.to_s
      assert_match "https://a-new-tunnel.ngrok-free.app/webhooks/github", elements.first.to_s
    end
    assert_select "[data-testid=re-register-button]"
  end

  test "a subscription whose callback still matches shows no warning" do
    sign_in_as @user
    stub_github_get("/user/repos", fixture: "repos")

    get webhook_subscriptions_path

    assert_select "[data-testid=subscription-stale]", false
    assert_select "[data-testid=re-register-button]", false
  end

  test "re-registering updates the hook in place rather than recreating it" do
    ENV["PRISM_PUBLIC_URL"] = "https://a-new-tunnel.ngrok-free.app"
    sign_in_as @user
    subscription = webhook_subscriptions(:docs_site)
    stub_github_patch("/repos/acme/docs-site/hooks/555", body: hook_payload(id: 555))

    assert_no_difference "WebhookSubscription.count" do
      patch webhook_subscription_path(subscription)
    end

    body = github_request_body(:patch, "/repos/acme/docs-site/hooks/555")

    assert_equal "https://a-new-tunnel.ngrok-free.app/webhooks/github", body.dig("config", "url")
    # The secret has to be resent: PATCH replaces the whole config, and a
    # cleared secret would mean every later delivery arrives unsigned.
    assert_equal subscription.secret, body.dig("config", "secret")
    assert_equal [ "pull_request" ], body["events"]

    subscription.reload

    assert_equal "https://a-new-tunnel.ngrok-free.app/webhooks/github", subscription.callback_url
    assert_not subscription.callback_stale?
    assert_equal 555, subscription.hook_id, "the hook id must not change — it was updated, not recreated"
    assert_not_requested :post, "https://api.github.com/repos/acme/docs-site/hooks"
  end

  test "re-registering keeps the secret, the delivery log and the declined pull requests" do
    ENV["PRISM_PUBLIC_URL"] = "https://a-new-tunnel.ngrok-free.app"
    sign_in_as @user
    subscription = webhook_subscriptions(:docs_site)
    secret = subscription.secret
    subscription.webhook_deliveries.create!(delivery_id: "keep-me", event: "pull_request")
    subscription.pull_request_announcements.create!(pull_request_number: 42, state: "declined")
    stub_github_patch("/repos/acme/docs-site/hooks/555", body: hook_payload(id: 555))

    patch webhook_subscription_path(subscription)
    subscription.reload

    assert_equal secret, subscription.secret
    assert WebhookDelivery.exists?(delivery_id: "keep-me")
    assert_equal "declined", subscription.announcement_for(42).state,
                 "an author who asked Prism to stop must not be forgotten by a re-register"
  end

  test "re-registering revives a broken subscription, because GitHub just accepted us" do
    ENV["PRISM_PUBLIC_URL"] = "https://a-new-tunnel.ngrok-free.app"
    sign_in_as users(:octocat)
    subscription = webhook_subscriptions(:broken)
    stub_github_patch("/repos/octo/hello-world/hooks/556", body: hook_payload(id: 556))

    patch webhook_subscription_path(subscription)

    assert subscription.reload.active?
    assert_nil subscription.broken_reason
  end

  # GitHub 404s the hooks endpoints for non-admins and for a hook that is
  # simply gone, so the fallback has to cover both.
  test "re-registering creates a hook when GitHub says the old one is gone" do
    ENV["PRISM_PUBLIC_URL"] = "https://a-new-tunnel.ngrok-free.app"
    sign_in_as @user
    subscription = webhook_subscriptions(:docs_site)
    stub_github_error(:patch, "/repos/acme/docs-site/hooks/555", status: 404, message: "Not Found")
    stub_github_post("/repos/acme/docs-site/hooks", body: hook_payload(id: 8888))

    patch webhook_subscription_path(subscription)

    assert_equal 8888, subscription.reload.hook_id
  end

  test "re-registering explains a lost admin grant" do
    ENV["PRISM_PUBLIC_URL"] = "https://a-new-tunnel.ngrok-free.app"
    sign_in_as @user
    subscription = webhook_subscriptions(:docs_site)
    stub_github_error(:patch, "/repos/acme/docs-site/hooks/555", status: 404, message: "Not Found")
    stub_github_error(:post, "/repos/acme/docs-site/hooks", status: 404, message: "Not Found")

    patch webhook_subscription_path(subscription)

    assert_match(/admin access/, flash[:alert])
    assert WebhookSubscription.exists?(subscription.id), "a failed re-register must not delete the subscription"
  end

  test "re-registering with no public URL says so instead of calling GitHub" do
    ENV.delete("PRISM_PUBLIC_URL")
    sign_in_as @user

    patch webhook_subscription_path(webhook_subscriptions(:docs_site))

    assert_match(/PRISM_PUBLIC_URL/, flash[:alert])
    assert_not_requested :any, /api\.github\.com/
  end

  test "one person cannot re-register another's repository" do
    sign_in_as users(:octocat)

    patch webhook_subscription_path(webhook_subscriptions(:docs_site))

    assert_response :not_found
    assert_not_requested :any, /api\.github\.com/
  end

  # ── Unsubscribing ──────────────────────────────────────────────────────

  test "unsubscribing deletes the hook on GitHub as well as the row" do
    sign_in_as @user
    subscription = webhook_subscriptions(:docs_site)
    stub_github_delete("/repos/acme/docs-site/hooks/555")

    assert_difference "WebhookSubscription.count", -1 do
      delete webhook_subscription_path(subscription)
    end

    assert_requested :delete, "https://api.github.com/repos/acme/docs-site/hooks/555"
    assert_redirected_to webhook_subscriptions_path
  end

  test "a hook that is already gone is not an error" do
    sign_in_as @user
    subscription = webhook_subscriptions(:docs_site)
    stub_github_error(:delete, "/repos/acme/docs-site/hooks/555", status: 404, message: "Not Found")

    assert_difference "WebhookSubscription.count", -1 do
      delete webhook_subscription_path(subscription)
    end

    assert_nil flash[:alert]
  end

  test "says what to do by hand when GitHub will not delete the hook" do
    sign_in_as @user
    subscription = webhook_subscriptions(:docs_site)
    stub_github_error(:delete, "/repos/acme/docs-site/hooks/555", status: 403, message: "Forbidden")

    assert_difference "WebhookSubscription.count", -1 do
      delete webhook_subscription_path(subscription)
    end

    assert_match(/Settings → Webhooks/, flash[:alert])
  end

  test "one person cannot unsubscribe another's repository" do
    sign_in_as users(:octocat)
    subscription = webhook_subscriptions(:docs_site)

    delete webhook_subscription_path(subscription)

    assert_response :not_found
    assert WebhookSubscription.exists?(subscription.id)
    assert_not_requested :any, /api\.github\.com/
  end

  private

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
