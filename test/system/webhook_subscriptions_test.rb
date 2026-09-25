# frozen_string_literal: true

require "application_system_test_case"

# Subscribing a repository, end to end in the browser: the screen has to say
# whose account Prism will act as *before* the button, the hook has to be
# registered on GitHub, and unsubscribing has to take it away again.
class WebhookSubscriptionsSystemTest < ApplicationSystemTestCase
  CALLBACK = "https://prism.test/webhooks/github"

  setup do
    @user = users(:prism_dev)
    ENV["PRISM_PUBLIC_URL"] = "https://prism.test"
    stub_github_get("/user/repos", fixture: :repos)
    # Signing in and re-registering both queue a reconciliation pass, and jobs
    # run inline here.
    stub_no_open_pull_requests
  end

  teardown { ENV.delete("PRISM_PUBLIC_URL") }

  test "subscribing a repository registers a webhook and says who it acts as" do
    stub_github_get("/repos/prism-dev/scratchpad", body: repo_payload("prism-dev", "scratchpad"))
    stub_github_post("/repos/prism-dev/scratchpad/hooks", body: hook_payload(id: 4242))

    sign_in_as @user
    visit webhook_subscriptions_path

    # The consent has to be on the screen before the button, not after it:
    # Prism is about to write into someone's pull request under this name.
    within "[data-testid=acting-as-notice]" do
      assert_text "edits its pull requests under your name"
      assert_text "coming from your account, @prism-dev"
    end

    select "prism-dev/scratchpad", from: "Repository"
    click_on "Watch repository"

    assert_text "Prism is watching prism-dev/scratchpad"
    within "[data-testid=subscription-list]" do
      assert_text "scratchpad"
      assert_text "as @prism-dev"
    end

    subscription = WebhookSubscription.find_by!(name: "scratchpad")
    request_body = github_request_body(:post, "/repos/prism-dev/scratchpad/hooks")

    assert_equal [ "pull_request" ], request_body["events"]
    assert_equal CALLBACK, request_body.dig("config", "url")
    assert_equal subscription.secret, request_body.dig("config", "secret")

    assert_no_csp_violations
  end

  test "a repository the account does not administer explains itself" do
    stub_github_get("/repos/prism-dev/scratchpad", body: repo_payload("prism-dev", "scratchpad"))
    stub_github_error(:post, "/repos/prism-dev/scratchpad/hooks", status: 404, message: "Not Found")

    sign_in_as @user
    visit webhook_subscriptions_path

    select "prism-dev/scratchpad", from: "Repository"
    click_on "Watch repository"

    assert_text "You need admin access to prism-dev/scratchpad"
    assert_no_selector "[data-testid=subscription-row]", text: "scratchpad"
  end

  test "unsubscribing deletes the hook on GitHub" do
    stub_github_delete("/repos/acme/docs-site/hooks/555")

    sign_in_as @user
    visit webhook_subscriptions_path

    assert_selector "[data-testid=subscription-row]", text: "docs-site"

    accept_confirm { click_on "Stop watching" }

    assert_text "stopped watching acme/docs-site"
    assert_no_selector "[data-testid=subscription-row]"
    assert_requested :delete, "https://api.github.com/repos/acme/docs-site/hooks/555"
  end

  test "the account menu leads to the screen" do
    sign_in_as @user
    visit root_path

    find("[data-testid=account-menu] summary").click
    click_on "Watched repositories"

    assert_selector "h1", text: "Watched repositories"
  end

  test "a moved tunnel is visible and re-registering fixes it in place" do
    ENV["PRISM_PUBLIC_URL"] = "https://a-new-tunnel.ngrok-free.app"
    stub_github_patch("/repos/acme/docs-site/hooks/555",
                      body: hook_payload(id: 555).merge(
                        "config" => { "url" => "https://a-new-tunnel.ngrok-free.app/webhooks/github" }
                      ))

    sign_in_as @user
    visit webhook_subscriptions_path

    assert_selector "[data-testid=subscription-stale]", text: "Wrong address"
    assert_selector "[data-testid=stale-reason]", text: "Nothing is arriving"

    click_on "Re-register"

    assert_text "GitHub is now delivering acme/docs-site"
    assert_no_selector "[data-testid=subscription-stale]"
    assert_selector "[data-testid=subscription-row]", text: "Active"
    assert_requested :patch, "https://api.github.com/repos/acme/docs-site/hooks/555"
  end

  # The state the production bug left people in: the screen used to tell them
  # to remove and re-add the repository, which was work they never needed to
  # do, for something that fixes itself.
  test "a suspended subscription reads as retrying, not as something to fix" do
    # Suspended *after* signing in on purpose: signing in heals it, which the
    # next test covers. This is the state someone sees when the refusal came
    # after their last sign-in.
    sign_in_as @user
    webhook_subscriptions(:docs_site).suspend!("GitHub refused this account's token")

    visit webhook_subscriptions_path

    assert_selector "[data-testid=subscription-suspended]", text: "Retrying"
    assert_selector "[data-testid=suspended-reason]", text: /on the next pull request in this repository/
    # Fault 2's other half: retrying must not depend on the repository being
    # busy enough to produce a delivery.
    assert_selector "[data-testid=suspended-reason]", text: /every couple of hours regardless/
    assert_selector "[data-testid=suspended-reason]", text: /signing in to Prism again/i
    assert_no_selector "[data-testid=broken-reason]"
    assert_no_text "remove and re-add"
  end

  test "signing in again clears a suspension without anyone asking" do
    webhook_subscriptions(:docs_site).suspend!("GitHub refused this account's token")

    sign_in_as @user
    visit webhook_subscriptions_path

    assert_selector "[data-testid=subscription-row]", text: "Active"
    assert_no_selector "[data-testid=subscription-suspended]"
  end

  test "a subscription broken by something no credential can reach says to add it again" do
    webhook_subscriptions(:docs_site).abandon!("The repository is gone from GitHub.")

    sign_in_as @user
    visit webhook_subscriptions_path

    assert_selector "[data-testid=subscription-broken]", text: "Not working"
    assert_selector "[data-testid=broken-reason]", text: "The repository is gone from GitHub."
    assert_selector "[data-testid=broken-reason]", text: /add it again/
    assert_no_text "Signing in to Prism again"
  end

  # Fault 3 on the screen. `broken` used to be unreachable by the one thing
  # that fixes it, and the copy said so — "stop watching this repository and
  # add it again" was the only way out even when the recorded reason was that
  # GitHub had refused the token. Signing in has to be offered, and has to
  # work.
  test "a subscription broken by a refused token comes back on the next sign-in" do
    subscription = webhook_subscriptions(:docs_site)
    subscription.suspend!("GitHub refused this account's token.")
    travel_to (WebhookSubscription::GIVE_UP_AFTER + 1.day).from_now do
      subscription.suspend!("GitHub refused this account's token.")
    end

    assert subscription.reload.broken?

    sign_in_as @user
    visit webhook_subscriptions_path

    # Signing in is itself the fix, so by the time this screen renders the
    # subscription is already watching again.
    assert_selector "[data-testid=subscription-row]", text: "Active"
    assert_no_selector "[data-testid=subscription-broken]"
  end

  # Reachable inside one long session: the sessions last 30 days, so a
  # subscription can break and give up without the reader ever signing in
  # again. The copy has to offer the fix that works rather than the one that
  # does not.
  test "a subscription broken by a refused token offers signing in, not re-adding" do
    sign_in_as @user

    subscription = webhook_subscriptions(:docs_site)
    subscription.suspend!("GitHub refused access.")
    travel_to (WebhookSubscription::GIVE_UP_AFTER + 1.day).from_now do
      subscription.suspend!("GitHub refused access.")
    end

    assert subscription.reload.broken?

    visit webhook_subscriptions_path

    assert_selector "[data-testid=subscription-broken]", text: "Not working"
    assert_selector "[data-testid=broken-reason]", text: /Signing in to Prism again/
    assert_selector "[data-testid=broken-reason]", text: /30 days/
    assert_no_text "add it again to start over"
  end

  private

  def repo_payload(owner, name, id: 555_001)
    { "id" => id, "name" => name, "full_name" => "#{owner}/#{name}", "private" => false,
      "description" => nil, "default_branch" => "main", "pushed_at" => "2026-09-18T16:30:00Z",
      "open_issues_count" => 0, "html_url" => "https://github.com/#{owner}/#{name}",
      "owner" => { "login" => owner, "avatar_url" => "https://example.test/a.png", "type" => "User" } }
  end

  def hook_payload(id:)
    { "id" => id, "type" => "Repository", "name" => "web", "active" => true,
      "events" => [ "pull_request" ],
      "config" => { "url" => CALLBACK, "content_type" => "json", "insecure_ssl" => "0" } }
  end
end
