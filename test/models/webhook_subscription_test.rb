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
    assert subscription.failing_since.present?, "the clock has to start on the first refusal"
    assert_nil subscription.broken_at, "nothing was given up on"
    assert_equal 1, subscription.consecutive_failures
  end

  test "success clears the suspension, the failure count and the clock" do
    subscription = webhook_subscriptions(:docs_site)
    3.times { subscription.suspend!("nope") }

    subscription.mark_active!

    assert subscription.active?
    assert_nil subscription.broken_reason
    assert_nil subscription.failing_since
    assert_nil subscription.failure_cause
    assert_equal 0, subscription.consecutive_failures
  end

  # Fault 2, in one test. The old rule counted deliveries, so how long a
  # subscription survived a broken token depended on how busy its repository
  # was: a busy one burned twenty refusals in an afternoon and was abandoned,
  # a quiet one on the same dead token spent six and recovered. The rule must
  # measure the outage, not the traffic.
  test "how long we have been failing decides giving up, not how many times" do
    busy = webhook_subscriptions(:docs_site)
    quiet = webhook_subscriptions(:broken)
    quiet.mark_active!

    travel_to Time.current do
      50.times { busy.suspend!("nope") }
      quiet.suspend!("nope")
    end

    assert busy.suspended?, "fifty refusals inside an afternoon is still an afternoon"
    assert quiet.suspended?

    # The same outage, still unfixed a month later, on both repositories.
    travel_to (WebhookSubscription::GIVE_UP_AFTER + 1.day).from_now do
      busy.suspend!("nope")
      quiet.suspend!("nope")

      assert busy.broken?
      assert quiet.broken?, "a quiet repository must give up on the same schedule as a busy one"
    end
  end

  test "giving up takes the whole of GIVE_UP_AFTER, and nothing before it" do
    subscription = webhook_subscriptions(:docs_site)

    subscription.suspend!("nope")

    travel_to (WebhookSubscription::GIVE_UP_AFTER - 1.hour).from_now do
      subscription.suspend!("nope")

      assert subscription.suspended?, "gave up too early"
      assert subscription.actable?
    end

    travel_to (WebhookSubscription::GIVE_UP_AFTER + 1.hour).from_now do
      subscription.suspend!("nope")

      assert subscription.broken?
      assert subscription.broken_at.present?
      assert_not subscription.actable?, "an abandoned subscription must not keep calling GitHub"
    end
  end

  # Otherwise an old, long-fixed outage adds itself to a new one and trips the
  # threshold the moment the next thing goes wrong.
  test "a success in between restarts the clock toward giving up" do
    subscription = webhook_subscriptions(:docs_site)

    subscription.suspend!("nope")

    travel_to (WebhookSubscription::GIVE_UP_AFTER + 1.day).from_now do
      subscription.mark_active!
      subscription.suspend!("nope")

      assert subscription.suspended?
      assert_equal 1, subscription.consecutive_failures
    end
  end

  test "a permanent failure stops immediately, whatever the clock says" do
    subscription = webhook_subscriptions(:docs_site)

    subscription.abandon!("the repository is gone")

    assert subscription.broken?
    assert_equal WebhookSubscription::PERMANENT, subscription.failure_cause
    assert_not subscription.actable?
  end

  # `webhook_deliveries` is pruned at a fortnight and we give up at thirty
  # days, so by the time anyone asks "why did watching stop?", every delivery
  # that could have answered is gone. The row has to answer on its own.
  test "giving up writes a reason that still explains itself after the deliveries are pruned" do
    subscription = webhook_subscriptions(:docs_site)
    started = Time.utc(2026, 8, 1, 9, 30)

    travel_to(started) { subscription.suspend!("GitHub refused this account's token.") }
    travel_to(started + 40.days) { 4.times { subscription.suspend!("GitHub refused access.") } }

    assert subscription.broken?
    reason = subscription.broken_reason

    assert_match(/GitHub refused access\./, reason, "what refused us")
    assert_match(/2026-08-01 09:30 UTC/, reason, "when the run started")
    assert_match(/5 attempts/, reason, "how hard we tried")
    assert_match(/30 days/, reason, "how long we waited")
  end

  test "a reason only summarises when we actually gave up" do
    subscription = webhook_subscriptions(:docs_site)

    subscription.suspend!("GitHub refused this account's token.")

    assert_equal "GitHub refused this account's token.", subscription.broken_reason
  end

  # Fault 3. Production held a subscription that was `broken` with
  # `broken_reason: "GitHub refused this account's token…"` — so the thing
  # that broke it plainly *was* the token — and a working token could not
  # reach it.
  test "a fresh token revives a subscription a credential broke, even after we gave up" do
    subscription = webhook_subscriptions(:docs_site)
    subscription.suspend!("GitHub refused this account's token")
    travel_to (WebhookSubscription::GIVE_UP_AFTER + 1.day).from_now do
      subscription.suspend!("GitHub refused this account's token")
    end

    assert subscription.broken?

    subscription.revive_after_new_token!

    assert subscription.active?
    assert_nil subscription.failing_since, "the revived subscription gets a fresh clock"
  end

  test "a fresh token does not revive a subscription a credential did not break" do
    abandoned = webhook_subscriptions(:broken)
    abandoned.abandon!("the repository is gone")

    abandoned.revive_after_new_token!

    assert abandoned.broken?, "a new token is no evidence that a deleted repository is back"
  end

  test "revivable picks out exactly what a credential is evidence about" do
    suspended = webhook_subscriptions(:docs_site)
    suspended.suspend!("GitHub refused this account's token")
    gone = webhook_subscriptions(:broken)
    gone.abandon!("the repository is gone")

    assert_includes WebhookSubscription.revivable, suspended
    assert_not_includes WebhookSubscription.revivable, gone
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

  # ── Announcement bookkeeping ───────────────────────────────────────────

  # Fault 4. `find_or_initialize_by` through the association put the unsaved
  # row into the association's target, and Active Record autosaves those when
  # the parent is saved — so the rescue that ran *because* GitHub had raised,
  # and which saves the subscription to suspend it, quietly persisted an
  # announcement recording an outcome that never happened.
  test "an announcement Prism has not decided anything about is not saved by saving the subscription" do
    subscription = webhook_subscriptions(:docs_site)

    subscription.announcement_for(42)

    assert_no_difference "PullRequestAnnouncement.count" do
      subscription.suspend!("GitHub refused this account's token")
    end
  end

  test "announcement_for returns the existing row when there is one" do
    subscription = webhook_subscriptions(:docs_site)
    existing = subscription.pull_request_announcements.create!(pull_request_number: 42, state: "present")

    assert_equal existing, subscription.announcement_for(42)
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
