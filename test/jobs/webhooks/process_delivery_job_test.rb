# frozen_string_literal: true

require "test_helper"

# What Prism actually does to a pull request, per event shape.
class Webhooks::ProcessDeliveryJobTest < ActiveJob::TestCase
  include WebhookHelpers

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

  test "a revoked token breaks the subscription instead of retrying" do
    @subscription.user.revoke_token!

    perform(action: "opened")

    assert @subscription.reload.broken?
    assert_match(/token is gone/, @subscription.broken_reason)
    assert_not_requested :get, github_url(PULL_PATH)
  end

  # The files listing is the first GitHub call the announcer makes, so that is
  # where a dead token shows up.
  test "a 401 from GitHub breaks the subscription and does not raise" do
    stub_github_error(:get, "#{PULL_PATH}/files", status: 401, message: "Bad credentials")

    delivery = build_delivery(action: "opened")
    Webhooks::ProcessDeliveryJob.perform_now(delivery.id)

    assert @subscription.reload.broken?
    assert_equal "failed", delivery.reload.status
  end

  test "a 403 breaks the subscription too" do
    stub_github_error(:get, "#{PULL_PATH}/files", status: 403, message: "Resource not accessible")

    perform(action: "opened")

    assert @subscription.reload.broken?
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
