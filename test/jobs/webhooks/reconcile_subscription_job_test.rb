# frozen_string_literal: true

require "test_helper"

class Webhooks::ReconcileSubscriptionJobTest < ActiveJob::TestCase
  include WebhookHelpers
  include AuthenticationHelpers

  REPO = "acme/docs-site"
  REVIEW_URL = "https://prism.test/acme/docs-site/pulls/42/markdown"

  setup do
    @subscription = webhook_subscriptions(:docs_site)
    @subscription.update!(created_at: 2.years.ago)
    ENV["PRISM_PUBLIC_URL"] = "https://prism.test"
  end

  teardown { ENV.delete("PRISM_PUBLIC_URL") }

  # ── Fault 1, end to end ────────────────────────────────────────────────

  # The production incident, in one test. A token starts being refused; every
  # delivery in the window fails and is lost; the user signs in again and the
  # token is healthy. Before this, the pull requests opened during the outage
  # stayed without their link for good, because nothing ever looked at them
  # again.
  test "a pull request whose delivery was refused gets its link once the token is fixed" do
    stub_github_error(:get, "/repos/#{REPO}/pulls/42/files", status: 401, message: "Bad credentials")
    delivery = @subscription.webhook_deliveries.create!(
      delivery_id: SecureRandom.uuid, event: "pull_request", action: "opened", pull_request_number: 42
    )
    Webhooks::ProcessDeliveryJob.perform_now(delivery.id)

    assert_equal "failed", delivery.reload.status
    assert @subscription.reload.suspended?

    WebMock.reset!
    stub_open_pulls
    stub_pull(42, body: "Tightens the prose.")
    stub_pull(41, body: "Also docs.")

    perform_enqueued_jobs do
      User.from_omniauth(github_auth_hash(@subscription.user, token: @subscription.user.access_token))
    end

    assert @subscription.reload.active?
    assert_includes patched_body(42), REVIEW_URL
    assert_equal "present", @subscription.announcement_for(42).state
  end

  test "signing in queues a pass for every subscription a credential broke" do
    @subscription.suspend!("GitHub refused this account's token")
    user = @subscription.user

    assert_enqueued_with job: Webhooks::ReconcileSubscriptionJob, args: [ @subscription.id ] do
      User.from_omniauth(github_auth_hash(user, token: user.access_token))
    end
  end

  # ── Failure policy, which must match the delivery path's ───────────────

  test "a refused token suspends the subscription rather than killing it" do
    stub_github_error(:get, "/repos/#{REPO}/pulls", status: 401, message: "Bad credentials")

    Webhooks::ReconcileSubscriptionJob.perform_now(@subscription.id)

    assert @subscription.reload.suspended?
    assert_not @subscription.broken?
    assert_match(/GitHub refused this account's token/, @subscription.broken_reason)
  end

  test "a 403 suspends too" do
    stub_github_error(:get, "/repos/#{REPO}/pulls", status: 403, message: "Resource not accessible")

    Webhooks::ReconcileSubscriptionJob.perform_now(@subscription.id)

    assert @subscription.reload.suspended?
  end

  # Nothing about one 404 distinguishes "deleted" from "private to you now",
  # and the delivery path leaves the subscription alone for the same reason.
  test "a 404 leaves the subscription alone" do
    stub_github_error(:get, "/repos/#{REPO}/pulls", status: 404, message: "Not Found")

    Webhooks::ReconcileSubscriptionJob.perform_now(@subscription.id)

    assert @subscription.reload.active?
  end

  test "a rate limit is retried, not swallowed" do
    stub_github_error(:get, "/repos/#{REPO}/pulls", status: 403,
                                                    message: "You have exceeded a secondary rate limit",
                                                    headers: { "Retry-After" => "60" })

    assert_enqueued_with job: Webhooks::ReconcileSubscriptionJob do
      Webhooks::ReconcileSubscriptionJob.perform_now(@subscription.id)
    end
  end

  # The clock has to run on a subscription that cannot work for want of a
  # token, or a signed-out subscriber would sit "active" forever doing nothing.
  test "a signed-out subscriber is recorded, not silently skipped" do
    @subscription.user.revoke_token!

    Webhooks::ReconcileSubscriptionJob.perform_now(@subscription.id)

    assert @subscription.reload.suspended?
    assert_equal "the subscriber is signed out of Prism", @subscription.broken_reason
    assert_not_requested :any, /api\.github\.com/
  end

  test "a scheduled pass does not resurrect a subscription Prism gave up on" do
    @subscription.abandon!("the repository is gone")

    Webhooks::ReconcileSubscriptionJob.perform_now(@subscription.id)

    assert @subscription.reload.broken?
    assert_not_requested :any, /api\.github\.com/
  end

  test "a subscription deleted while queued is discarded quietly" do
    assert_nothing_raised { Webhooks::ReconcileSubscriptionJob.perform_now(0) }
  end

  private

  def stub_open_pulls
    stub_github_get("/repos/#{REPO}/pulls", body: github_fixture("pulls"))
  end

  def stub_pull(number, body:)
    stub_github_get("/repos/#{REPO}/pulls/#{number}",
                    body: github_fixture("pull").merge("number" => number, "body" => body))
    stub_github_get("/repos/#{REPO}/pulls/#{number}/files", body: github_fixture("pull_files"))
    stub_request(:patch, "https://api.github.com/repos/#{REPO}/pulls/#{number}")
      .to_return(status: 200, body: github_fixture("pull").to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  def patched_body(number)
    github_request_body(:patch, "/repos/#{REPO}/pulls/#{number}").fetch("body")
  end
end
