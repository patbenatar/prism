# frozen_string_literal: true

require "test_helper"

# What Prism actually does to a pull request, per event shape.
class Webhooks::ProcessDeliveryJobTest < ActiveJob::TestCase
  include WebhookHelpers
  # For github_auth_hash: the sign-in heal is driven through the real
  # User.from_omniauth rather than by poking the column.
  include AuthenticationHelpers

  REPO = "acme/docs-site"
  PULL_PATH = "/repos/acme/docs-site/pulls/42"
  MARKER_BEGIN = Webhooks::MarkerBlock::BEGIN_MARKER
  MARKER_END = Webhooks::MarkerBlock::END_MARKER

  # The canonical review screen: ws-pr-tabs' single page of every renderable
  # Markdown file in the pull request.
  REVIEW_URL = "https://prism.test/acme/docs-site/pulls/42/markdown"

  setup do
    @subscription = webhook_subscriptions(:docs_site)
    ENV["PRISM_PUBLIC_URL"] = "https://prism.test"
  end

  teardown { ENV.delete("PRISM_PUBLIC_URL") }

  # ── opened ─────────────────────────────────────────────────────────────

  test "a pull request opened with Markdown gets the link" do
    stub_pull(body: "Tightens the prose.")
    patch_stub = stub_patch

    perform(action: "opened")

    assert_requested patch_stub
    body = patched_body

    assert_includes body, MARKER_BEGIN
    assert_includes body, REVIEW_URL
    assert_includes body, "3 Markdown files", "docs/legacy.md is removed and must not be counted"
    assert_equal "present", announcement.state
    assert_equal 3, announcement.renderable_count
  end

  test "a pull request opened with no Markdown is left alone" do
    stub_pull(body: "Bumps a dependency.", files: :no_markdown)

    perform(action: "opened")

    assert_not_requested :patch, github_url(PULL_PATH)
    assert_equal "absent", announcement.state
  end

  test "a pull request whose only Markdown change is a deletion is left alone" do
    stub_pull(body: "Drops the old guide.", files: :only_removed_markdown)

    perform(action: "opened")

    assert_not_requested :patch, github_url(PULL_PATH)
  end

  test "one Markdown file reads as one, not three" do
    stub_pull(body: "Adds a README.", files: :one_markdown)
    stub_patch

    perform(action: "opened")

    assert_includes patched_body, "1 Markdown file"
    assert_not_includes patched_body, "1 Markdown files"
  end

  # ── synchronize ────────────────────────────────────────────────────────

  test "a push that adds the first Markdown file adds the link" do
    announcement.update!(state: "absent")
    stub_pull(body: "Now with docs.", files: :one_markdown)
    stub_patch

    perform(action: "synchronize")

    assert_includes patched_body, MARKER_BEGIN
    assert_equal "present", announcement.reload.state
  end

  test "a push that removes the last Markdown file takes the link away" do
    announcement.update!(state: "present", renderable_count: 1)
    original = "Reverts the docs.\n\n#{block_with('stale link')}"
    stub_pull(body: original, files: :no_markdown)
    stub_patch

    perform(action: "synchronize")

    assert_equal "Reverts the docs.\n\n", patched_body
    assert_equal "absent", announcement.reload.state
  end

  # ── Idempotency ────────────────────────────────────────────────────────

  test "a pull request already carrying the right block is not written to" do
    stub_pull(body: "Tightens the prose.")
    stub_patch
    perform(action: "opened", delivery_id: "first")

    settled = patched_body
    reset_stubs
    stub_pull(body: settled)
    stub_patch

    perform(action: "synchronize", delivery_id: "second")

    # The block was already correct, so writing it again would be a wasted
    # GitHub call and a pointless "edited" event.
    assert_not_requested :patch, github_url(PULL_PATH)
  end

  test "running the same delivery twice converges on one block" do
    stub_pull(body: "Tightens the prose.")
    stub_patch
    delivery = build_delivery(action: "opened")

    Webhooks::ProcessDeliveryJob.perform_now(delivery.id)
    first = patched_body

    reset_stubs
    stub_pull(body: first)
    stub_patch
    Webhooks::ProcessDeliveryJob.perform_now(delivery.id)

    assert_equal 1, first.scan(MARKER_BEGIN).size
  end

  # ── The promise ────────────────────────────────────────────────────────

  test "editing the description preserves every byte outside the markers" do
    before = "## Summary\n\nProse with  odd   spacing\tand a tab.\n\n### Notes\n"
    after = "\n\nCloses #12\n\n<!-- a tool that is not us -->\nleave me\n"
    stub_pull(body: "#{before}#{block_with('old link')}#{after}")
    stub_patch

    perform(action: "synchronize")

    body = patched_body

    assert body.start_with?(before), "text before the block changed"
    assert body.end_with?(after), "text after the block changed"
    assert_includes body, REVIEW_URL
    assert_not_includes body, "old link"
  end

  test "an author's edits around our block survive a later push" do
    stub_pull(body: "First draft.")
    stub_patch
    perform(action: "opened", delivery_id: "one")

    edited = patched_body.sub("First draft.", "Second draft, rewritten by hand.") + "\n\nPS: added later."
    reset_stubs
    stub_pull(body: edited, files: :one_markdown)
    stub_patch

    perform(action: "synchronize", delivery_id: "two")

    body = patched_body

    assert_includes body, "Second draft, rewritten by hand."
    assert_includes body, "PS: added later."
    assert_includes body, "1 Markdown file"
  end

  # ── The author said no ─────────────────────────────────────────────────

  test "deleting our block by hand stops Prism adding it again" do
    announcement.update!(state: "present", renderable_count: 3)
    stub_pull(body: "I deleted Prism's paragraph, thanks.")

    perform(action: "synchronize")

    assert_not_requested :patch, github_url(PULL_PATH)
    assert_equal "declined", announcement.reload.state
  end

  test "a declined pull request is left alone forever, without a GitHub call" do
    announcement.update!(state: "declined")

    perform(action: "synchronize")

    assert_not_requested :get, github_url(PULL_PATH)
    assert_not_requested :patch, github_url(PULL_PATH)
  end

  # ── Failure handling ───────────────────────────────────────────────────

  test "a signed-out subscriber suspends the subscription rather than killing it" do
    @subscription.user.revoke_token!

    perform(action: "opened")

    assert @subscription.reload.suspended?
    assert_not @subscription.broken?
    assert_not_requested :get, github_url(PULL_PATH)
  end

  # The files listing is the first GitHub call the announcer makes, so that is
  # where a refused token shows up.
  test "a 401 from GitHub suspends the subscription and does not raise" do
    stub_github_error(:get, "#{PULL_PATH}/files", status: 401, message: "Bad credentials")

    delivery = build_delivery(action: "opened")
    Webhooks::ProcessDeliveryJob.perform_now(delivery.id)

    assert @subscription.reload.suspended?
    assert_not @subscription.broken?
    assert_equal "failed", delivery.reload.status
    assert_match(/will retry on the next delivery/, delivery.result)
  end

  test "a 403 suspends too" do
    stub_github_error(:get, "#{PULL_PATH}/files", status: 403, message: "Resource not accessible")

    perform(action: "opened")

    assert @subscription.reload.suspended?
  end

  # ── Recovery ───────────────────────────────────────────────────────────

  # The production bug, end to end: a refusal, then a delivery that works, and
  # the subscription is watching again with nobody having done anything.
  test "a suspended subscription recovers on the very next delivery" do
    stub_github_error(:get, "#{PULL_PATH}/files", status: 401, message: "Bad credentials")
    perform(action: "opened", delivery_id: "the-refusal")

    assert @subscription.reload.suspended?

    reset_stubs
    stub_pull(body: "Docs.")
    stub_patch

    perform(action: "synchronize", delivery_id: "the-recovery")

    assert @subscription.reload.active?
    assert_nil @subscription.broken_reason
    assert_equal 0, @subscription.consecutive_failures
    assert_includes patched_body, MARKER_BEGIN, "the recovered delivery must do its actual work"
  end

  # ── Recovery with nobody signing in ────────────────────────────────────
  #
  # The whole point of capturing the refresh token. Before it, an eight-hour
  # token expiring at 15:28 meant every delivery for the rest of the day was
  # refused and watching only came back when the subscriber happened to open
  # Prism. Now the delivery renews the credential on its way past.

  test "a delivery whose token expired renews it and does the work anyway" do
    subscriber = @subscription.user
    subscriber.update!(refresh_token: "ghr_old", access_token_expires_at: 1.minute.ago)
    stub_github_token_refresh(access_token: "gho_renewed", refresh_token: "ghr_rotated")
    stub_pull(body: "Docs.")
    stub_patch

    perform(action: "opened")

    assert_token_refreshed
    assert @subscription.reload.active?
    assert_includes patched_body, MARKER_BEGIN
    assert_equal "gho_renewed", subscriber.reload.access_token
    assert_equal "ghr_rotated", subscriber.refresh_token
  end

  # No human anywhere in this test. The subscription was suspended while the
  # token was refused, nobody signs in, and the next delivery is what puts it
  # right — because the delivery renews the credential itself.
  test "a subscription suspended for an expired token heals itself on the next delivery" do
    subscriber = @subscription.user
    subscriber.update!(refresh_token: "ghr_old", access_token_expires_at: 1.minute.ago)
    @subscription.suspend!(Webhooks::SubscriberJob::TOKEN_REFUSED)

    assert @subscription.reload.suspended?

    stub_github_token_refresh(access_token: "gho_renewed")
    stub_pull(body: "Docs.")
    stub_patch

    perform(action: "synchronize", delivery_id: "the-recovery")

    assert @subscription.reload.active?
    assert_equal 0, @subscription.consecutive_failures
    assert_nil @subscription.failing_since
    assert_includes patched_body, MARKER_BEGIN
  end

  # GitHub's token endpoint having a bad minute is not a verdict on anything.
  # It must not suspend the subscription and it must not clear the credential;
  # SubscriberJob's retry_on backs the whole job off instead.
  test "an outage at the token endpoint retries rather than suspending or signing out" do
    subscriber = @subscription.user
    subscriber.update!(refresh_token: "ghr_old", access_token_expires_at: 1.minute.ago)
    stub_github_token_unavailable(status: 503)

    assert_enqueued_with job: Webhooks::ProcessDeliveryJob do
      perform(action: "opened")
    end

    assert @subscription.reload.active?
    assert_not @subscription.suspended?

    subscriber.reload
    assert subscriber.token?
    assert subscriber.refreshable?, "an unreachable token endpoint must not cost anybody their refresh token"
  end

  # The one credential failure a refresh cannot fix. It must still land where
  # it always did — suspended, not abandoned, fixable by signing in.
  test "a refresh GitHub refuses suspends the subscription and needs a sign-in" do
    subscriber = @subscription.user
    subscriber.update!(refresh_token: "ghr_dead", access_token_expires_at: 1.minute.ago)
    stub_github_token_error("bad_refresh_token")

    perform(action: "opened")

    assert @subscription.reload.suspended?
    assert_not @subscription.broken?
    assert_not subscriber.reload.token?
    assert_not @subscription.actable?, "with no credential left there is nothing to act with"

    User.from_omniauth(github_auth_hash(subscriber, token: "gho_after_sign_in", expiring: true))

    assert @subscription.reload.active?
    assert @subscription.actable?
  end

  test "a subscription abandoned after a long outage stays abandoned" do
    @subscription.abandon!("the repository is gone")

    assert @subscription.broken?

    perform(action: "opened")

    assert @subscription.reload.broken?
    assert_not_requested :any, /api\.github\.com/
  end

  # Fault 2: a busy repository used to die first, because twenty refusals is a
  # measure of how many pull requests happened to arrive during an outage, not
  # of how long the outage was. Fifty deliveries inside one afternoon must not
  # be enough on their own.
  test "a burst of refusals in one afternoon does not abandon a busy repository" do
    stub_github_error(:get, "#{PULL_PATH}/files", status: 401, message: "Bad credentials")

    50.times { |n| perform(action: "synchronize", delivery_id: "burst-#{n}") }

    assert @subscription.reload.suspended?
    assert_not @subscription.broken?, "watching a busy repository must not die faster than a quiet one"
  end

  test "giving up is recorded in the delivery log, so it is not a silent stop" do
    @subscription.suspend!("GitHub refused this account's token")
    stub_github_error(:get, "#{PULL_PATH}/files", status: 401, message: "Bad credentials")

    travel_to (WebhookSubscription::GIVE_UP_AFTER + 1.day).from_now do
      delivery = build_delivery(action: "opened")
      Webhooks::ProcessDeliveryJob.perform_now(delivery.id)

      assert @subscription.reload.broken?
      assert_match(/gave up after/, delivery.reload.result)
    end
  end

  # Fault 3: the production row was `broken` with a recorded reason that said
  # GitHub had refused the token, and a working token could not reach it.
  test "signing in again revives a subscription a credential broke, and goes back for what it missed" do
    @subscription.suspend!("GitHub refused this account's token")
    travel_to (WebhookSubscription::GIVE_UP_AFTER + 1.day).from_now do
      @subscription.suspend!("GitHub refused this account's token")
    end
    user = @subscription.user

    assert @subscription.reload.broken?

    assert_enqueued_with job: Webhooks::ReconcileSubscriptionJob, args: [ @subscription.id ] do
      User.from_omniauth(github_auth_hash(user, token: user.access_token))
    end

    assert @subscription.reload.active?
  end

  # Fault 4: the rescue that suspends the subscription used to persist an
  # announcement the Announcer had never committed to — `state: "absent"`,
  # `last_event_at: nil` — which afterwards is indistinguishable from a pull
  # request Prism genuinely retracted from.
  test "a refused delivery records no announcement at all" do
    stub_github_error(:get, "#{PULL_PATH}/files", status: 401, message: "Bad credentials")

    assert_no_difference "PullRequestAnnouncement.count" do
      perform(action: "opened")
    end
  end

  # Recovering must not cost the record of who asked Prism to stop, or the
  # audit trail of what it did.
  test "recovery keeps the declined pull requests and the delivery history" do
    @subscription.pull_request_announcements.create!(pull_request_number: 99, state: "declined")
    stub_github_error(:get, "#{PULL_PATH}/files", status: 401, message: "Bad credentials")
    perform(action: "opened", delivery_id: "refusal")

    reset_stubs
    stub_pull(body: "Docs.")
    stub_patch
    perform(action: "synchronize", delivery_id: "recovery")

    assert @subscription.reload.active?
    assert_equal "declined", @subscription.announcement_for(99).state
    assert_equal 2, @subscription.webhook_deliveries.count
  end

  # Keyed on the sign-in rather than on the token changing: GitHub hands back
  # the same token when the grant is unchanged, and Active Record compares
  # decrypted values, so "the token changed" is false in exactly the case
  # where someone signs in to put things right.
  test "signing in again revives every suspended subscription, unchanged token or not" do
    @subscription.suspend!("GitHub refused this account's token")
    user = @subscription.user

    User.from_omniauth(github_auth_hash(user, token: user.access_token))

    assert @subscription.reload.active?
    assert_nil @subscription.broken_reason
    assert_equal 0, @subscription.consecutive_failures
  end

  test "a 404 is recorded but leaves the subscription alone" do
    stub_github_error(:get, "#{PULL_PATH}/files", status: 404, message: "Not Found")

    delivery = build_delivery(action: "opened")
    Webhooks::ProcessDeliveryJob.perform_now(delivery.id)

    assert_not @subscription.reload.broken?
    assert_equal "failed", delivery.reload.status
    assert_match(/not found/i, delivery.result)
  end

  test "a 403 rate limit is retried, not swallowed" do
    stub_github_error(:get, "#{PULL_PATH}/files", status: 403,
                                                  message: "You have exceeded a secondary rate limit",
                                                  headers: { "Retry-After" => "60" })

    delivery = build_delivery(action: "opened")

    assert_enqueued_with job: Webhooks::ProcessDeliveryJob do
      Webhooks::ProcessDeliveryJob.perform_now(delivery.id)
    end
  end

  # GitHub also sends a bare 429 for secondary limits, which Octokit does not
  # recognize as a rate limit on its own. Retrying it is the difference
  # between a delayed link and one that silently never appears.
  test "a bare 429 is retried too" do
    stub_github_error(:get, "#{PULL_PATH}/files", status: 429,
                                                  message: "You have exceeded a secondary rate limit",
                                                  headers: { "Retry-After" => "60" })

    delivery = build_delivery(action: "opened")

    assert_enqueued_with job: Webhooks::ProcessDeliveryJob do
      Webhooks::ProcessDeliveryJob.perform_now(delivery.id)
    end
  end

  test "a broken subscription does nothing and says so" do
    broken = webhook_subscriptions(:broken)
    delivery = broken.webhook_deliveries.create!(
      delivery_id: SecureRandom.uuid, event: "pull_request", action: "opened", pull_request_number: 7
    )

    Webhooks::ProcessDeliveryJob.perform_now(delivery.id)

    assert_equal "ignored", delivery.reload.status
    assert_not_requested :any, /api\.github\.com/
  end

  test "a delivery deleted while queued is discarded quietly" do
    assert_nothing_raised { Webhooks::ProcessDeliveryJob.perform_now(0) }
  end

  # ── The footer rule ────────────────────────────────────────────────────

  # The rule separates our line from the author's prose. It has to be inside
  # the markers: outside, it would survive every retraction and accumulate.
  test "the block opens with a horizontal rule, inside the markers" do
    stub_pull(body: "Docs.")
    stub_patch

    perform(action: "opened")

    body = patched_body

    assert_includes body, "#{MARKER_BEGIN}\n---\n"
    assert_equal 1, body.scan("---").size
  end

  test "retracting takes the rule with it and restores the author's text" do
    # Placed by the first delivery, not by hand: pre-setting the state to
    # "present" while the body has no block is exactly the shape that means
    # "the author deleted it", and the run would decline instead of placing.
    stub_pull(body: "Docs.")
    stub_patch
    perform(action: "opened", delivery_id: "place")

    with_block = patched_body
    reset_stubs
    stub_pull(body: with_block, files: :no_markdown)
    stub_patch

    perform(action: "synchronize", delivery_id: "retract")

    assert_equal "Docs.\n\n", patched_body
    assert_not_includes patched_body, "---", "a stray rule was left in the description"
  end

  test "the block carries no attribution line" do
    stub_pull(body: "Docs.")
    stub_patch

    perform(action: "opened")

    assert_not_includes patched_body, "on behalf of"
    assert_not_includes patched_body, "<sub>"
  end

  private

  def perform(action:, delivery_id: SecureRandom.uuid)
    Webhooks::ProcessDeliveryJob.perform_now(build_delivery(action: action, delivery_id: delivery_id).id)
  end

  def build_delivery(action:, delivery_id: SecureRandom.uuid, number: 42)
    @subscription.webhook_deliveries.create!(
      delivery_id: delivery_id, event: "pull_request", action: action, pull_request_number: number
    )
  end

  def announcement
    @subscription.pull_request_announcements.find_or_create_by!(pull_request_number: 42)
  end

  def github_url(path) = "https://api.github.com#{path}"

  def block_with(content) = "#{MARKER_BEGIN}\n#{content}\n#{MARKER_END}"

  def stub_pull(body:, files: :markdown)
    stub_github_get(PULL_PATH, body: pull_payload(body))
    stub_github_get("#{PULL_PATH}/files", body: files_payload(files))
  end

  def stub_patch
    stub_request(:patch, github_url(PULL_PATH))
      .to_return(status: 200, body: pull_payload("patched").to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  def patched_body
    github_request_body(:patch, PULL_PATH).fetch("body")
  end

  # WebMock keeps every stub and every recorded request for the test; a second
  # round of stubbing has to start from a clean slate or the first `to_return`
  # still wins and `github_request_body` reads the wrong call.
  def reset_stubs
    WebMock.reset!
  end

  def pull_payload(body)
    github_fixture("pull").merge("body" => body)
  end

  def files_payload(kind)
    case kind
    when :markdown then github_fixture("pull_files")
    when :no_markdown then github_fixture("pull_files").reject { |file| file["filename"].end_with?(".md") }
    when :one_markdown
      [ { "filename" => "README.md", "status" => "added", "additions" => 10, "deletions" => 0,
          "patch" => "@@ -0,0 +1,10 @@\n+hello", "blob_url" => "https://github.com/#{REPO}/blob/abc/README.md" } ]
    when :only_removed_markdown
      github_fixture("pull_files").select { |file| file["status"] == "removed" }
    else raise ArgumentError, "unknown files fixture #{kind.inspect}"
    end
  end
end
