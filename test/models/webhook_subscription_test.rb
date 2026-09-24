# frozen_string_literal: true

require "test_helper"

class WebhookSubscriptionTest < ActiveSupport::TestCase
  test "the secret is encrypted at rest" do
    subscription = webhook_subscriptions(:docs_site)
    stored = WebhookSubscription.connection.select_value(
      "SELECT secret FROM webhook_subscriptions WHERE id = #{subscription.id}"
    )

    assert_equal "whsec_docs_site_0123456789abcdef", subscription.secret
    assert_not_equal subscription.secret, stored, "the secret is readable in the database"
  end

  test "generated secrets are long and unpredictable" do
    secrets = 5.times.map { WebhookSubscription.generate_secret }

    assert_equal 5, secrets.uniq.size
    assert(secrets.all? { |secret| secret.length >= 64 })
  end

  test "one subscription per repository, whatever the casing" do
    duplicate = WebhookSubscription.new(
      user: users(:octocat), owner: "ACME", name: "Docs-Site", secret: "x"
    )

    assert_raises ActiveRecord::RecordNotUnique do
      duplicate.save!(validate: false)
    end
  end

  test "stores owner and name in GitHub's casing" do
    subscription = WebhookSubscription.create!(
      user: users(:prism_dev), owner: "Acme", name: "Docs-Portal", secret: "x"
    )

    assert_equal "Acme/Docs-Portal", subscription.full_name
  end

  test "finds a subscription by repository id even after a rename" do
    subscription = webhook_subscriptions(:docs_site)

    found = WebhookSubscription.for_repository(subscription.github_repo_id, "acme/renamed-entirely")

    assert_equal subscription, found
  end

  test "falls back to owner/name, case-insensitively, when the id is unknown" do
    assert_equal webhook_subscriptions(:docs_site), WebhookSubscription.for_repository(nil, "ACME/Docs-Site")
  end

  test "returns nothing for a repository nobody subscribed" do
    assert_nil WebhookSubscription.for_repository(12_345, "someone/else")
    assert_nil WebhookSubscription.for_repository(nil, "not-a-full-name")
  end

  # ── Suspending, recovering, and giving up ──────────────────────────────

  # The bug this replaced: a single refusal killed the subscription for good,
  # the user signed in again and fixed the token without knowing anything was
  # wrong, and nothing ever looked again.
  test "a refusal suspends rather than kills, and the subscription keeps acting" do
    subscription = webhook_subscriptions(:docs_site)

    subscription.suspend!("GitHub refused this account's token")

    assert subscription.suspended?
    assert_not subscription.broken?
    assert subscription.actable?, "a suspended subscription must still be tried"
    assert_equal "GitHub refused this account's token", subscription.broken_reason
    assert subscription.broken_at.present?
    assert_equal 1, subscription.consecutive_failures
  end

  test "success clears the suspension and the failure count" do
    subscription = webhook_subscriptions(:docs_site)
    3.times { subscription.suspend!("nope") }

    subscription.mark_active!

    assert subscription.active?
    assert_nil subscription.broken_reason
    assert_equal 0, subscription.consecutive_failures
  end

  test "giving up takes the agreed number of consecutive refusals" do
    subscription = webhook_subscriptions(:docs_site)
    limit = WebhookSubscription::MAX_CONSECUTIVE_FAILURES

    (limit - 1).times { subscription.suspend!("nope") }

    assert subscription.suspended?, "gave up too early"
    assert subscription.actable?

    subscription.suspend!("nope")

    assert subscription.broken?
    assert_not subscription.actable?, "an abandoned subscription must not keep calling GitHub"
  end

  # Otherwise an old, long-fixed problem adds itself to a new one and trips
  # the threshold early.
  test "a success in between resets the count toward giving up" do
    subscription = webhook_subscriptions(:docs_site)

    (WebhookSubscription::MAX_CONSECUTIVE_FAILURES - 1).times { subscription.suspend!("nope") }
    subscription.mark_active!
    subscription.suspend!("nope")

    assert subscription.suspended?
    assert_equal 1, subscription.consecutive_failures
  end

  test "a permanent failure stops immediately, whatever the count" do
    subscription = webhook_subscriptions(:docs_site)

    subscription.abandon!("the repository is gone")

    assert subscription.broken?
    assert_not subscription.actable?
  end

  test "a fresh token revives a suspended subscription but not an abandoned one" do
    suspended = webhook_subscriptions(:docs_site)
    suspended.suspend!("GitHub refused this account's token")
    abandoned = webhook_subscriptions(:broken)
    abandoned.abandon!("gave up")

    suspended.revive_after_new_token!
    abandoned.revive_after_new_token!

    assert suspended.active?
    assert abandoned.broken?, "a new token is no evidence that a repeated failure is fixed"
  end

  test "a user with no token cannot be acted as" do
    subscription = webhook_subscriptions(:docs_site)
    subscription.user.revoke_token!

    assert subscription.active?
    assert_not subscription.actable?
  end

  # A dev quick tunnel gets a new hostname on every restart, so this is the
  # normal case locally, not an edge case.
  test "a subscription whose callback no longer matches reads as stale" do
    subscription = webhook_subscriptions(:docs_site)

    with_public_url("https://prism.test") do
      assert_not subscription.callback_stale?
    end

    with_public_url("https://a-different-tunnel.ngrok-free.app") do
      assert subscription.callback_stale?
    end
  end

  test "nothing is stale when there is no public URL to compare against" do
    subscription = webhook_subscriptions(:docs_site)

    with_public_url(nil) do
      assert_not subscription.callback_stale?,
                 "an unset PRISM_PUBLIC_URL is its own, louder warning"
    end
  end

  test "a row registered before we recorded callbacks is not stale" do
    subscription = webhook_subscriptions(:docs_site)
    subscription.update!(callback_url: nil)

    with_public_url("https://somewhere-else.test") do
      assert_not subscription.callback_stale?
    end
  end

  test "destroying a subscription takes its deliveries and announcements with it" do
    subscription = webhook_subscriptions(:docs_site)
    subscription.webhook_deliveries.create!(delivery_id: SecureRandom.uuid, event: "pull_request")
    subscription.pull_request_announcements.create!(pull_request_number: 42, state: "present")

    assert_difference [ "WebhookDelivery.count", "PullRequestAnnouncement.count" ], -1 do
      subscription.destroy!
    end
  end
end
