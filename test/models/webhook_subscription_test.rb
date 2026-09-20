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

  test "marking broken records why and stops it being actable" do
    subscription = webhook_subscriptions(:docs_site)

    subscription.mark_broken!("GitHub rejected the token")

    assert subscription.broken?
    assert_not subscription.actable?
    assert_equal "GitHub rejected the token", subscription.broken_reason
    assert subscription.broken_at.present?
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
