# frozen_string_literal: true

require "test_helper"

# Reconciliation is the guarantee behind webhook delivery: whatever the events
# failed to tell Prism, this finds out by asking.
class Webhooks::ReconcilerTest < ActiveSupport::TestCase
  include WebhookHelpers

  REPO = "acme/docs-site"
  MARKER_BEGIN = Webhooks::MarkerBlock::BEGIN_MARKER
  MARKER_END = Webhooks::MarkerBlock::END_MARKER
  REVIEW_URL = "https://prism.test/acme/docs-site/pulls/42/markdown"

  setup do
    @subscription = webhook_subscriptions(:docs_site)
    # Fixtures are loaded now, so the fixture pull requests would all predate
    # the subscription. Watching started long ago for every test but the one
    # that is about that boundary.
    @subscription.update!(created_at: 2.years.ago)
    ENV["PRISM_PUBLIC_URL"] = "https://prism.test"
  end

  teardown { ENV.delete("PRISM_PUBLIC_URL") }

  # ── The fault this exists for ──────────────────────────────────────────

  # A token 401s for fourteen hours, every delivery in that window is refused
  # and lost, and the pull requests opened during it never get their link.
  # Nothing replayed them. This is what replays them.
  test "places the link on an open pull request that never got one" do
    stub_open_pulls
    stub_pull(42, body: "Tightens the prose.")
    stub_pull(41, body: "Also docs.")

    result = reconcile

    assert_equal :reconciled, result.status
    assert_equal 2, result.examined
    assert_equal 2, result.changed
    assert_includes patched_body(42), REVIEW_URL
    assert_equal "present", announcement(42).state
    assert_equal "present", announcement(41).state
  end

  test "a pull request already carrying the right link is not written to" do
    stub_open_pulls
    stub_pull(42, body: "Tightens the prose.")
    stub_pull(41, body: "Also docs.")
    reconcile

    settled_body = patched_body(42)
    WebMock.reset!
    stub_open_pulls
    stub_pull(42, body: settled_body)
    stub_pull(41, body: "Also docs.")

    # Announcements were stamped after the pull requests' `updated_at`, so
    # nothing is examined at all — the point of `settled?`.
    result = reconcile

    assert_equal 0, result.examined
    assert_not_requested :patch, github_url("/repos/#{REPO}/pulls/42")
  end

  # ── What a pass costs ──────────────────────────────────────────────────

  test "a healthy subscription costs one GitHub call" do
    settle(42)
    settle(41)
    list = stub_open_pulls

    result = reconcile

    assert_equal 0, result.examined
    assert_requested list, times: 1
    assert_not_requested :get, github_url("/repos/#{REPO}/pulls/42/files")
  end

  # ── Settling without comparing clocks ──────────────────────────────────

  # The first version of `settled?` compared our `last_event_at` against
  # GitHub's `updated_at` — one machine's clock against another's. Under skew
  # in one direction an author's edit landing inside the window reads as
  # already handled and is silently skipped, which is the exact failure this
  # workstream exists to remove. Equality against the value we recorded has no
  # window to be inside.
  test "a pull request is settled only by the exact state Prism acted on" do
    announcement_row(42).update!(state: "present",
                                 last_event_at: 10.years.ago,
                                 last_seen_updated_at: fixture_updated_at(42))
    settle(41)
    stub_open_pulls

    # `last_event_at` is a decade older than GitHub's `updated_at`, which the
    # old ordering would have read as "never looked". What matters is that the
    # state is the one we recorded.
    assert_equal 0, reconcile.examined
  end

  test "a clock running ahead of GitHub's cannot make a changed pull request look settled" do
    announcement_row(42).update!(state: "present",
                                 last_event_at: 1.year.from_now,
                                 last_seen_updated_at: fixture_updated_at(42) - 1.hour)
    settle(41)
    stub_open_pulls
    stub_pull(42, body: "Tightens the prose.")

    result = reconcile

    assert_equal 1, result.examined, "a different state must be examined however new our own stamp is"
  end

  test "what Prism saw is recorded with the outcome" do
    stub_open_pulls
    stub_pull(42, body: "Tightens the prose.")
    stub_pull(41, body: "Also docs.")

    reconcile

    assert_equal fixture_updated_at(42), announcement(42).last_seen_updated_at
  end

  # Our own PATCH moves GitHub's `updated_at` to a value we would have to
  # spend a call to learn, so the pass that writes records the state it came
  # in on and the next pass records the settled one. Converging, and it never
  # claims to have seen a state it did not see.
  test "a pass that wrote settles on the pass after it" do
    stub_open_pulls
    stub_pull(42, body: "Tightens the prose.")
    stub_pull(41, body: "Also docs.")
    reconcile

    settled_body = patched_body(42)
    WebMock.reset!
    # GitHub's clock moved when our edit landed.
    moved = github_fixture("pulls").map do |pull|
      pull["number"] == 42 ? pull.merge("updated_at" => "2026-09-19T08:00:00Z") : pull
    end
    stub_open_pulls(payload: moved)
    stub_pull(42, body: settled_body)

    second = reconcile

    assert_equal 1, second.examined
    assert_equal 0, second.changed, "the second look must find the link already correct"
    assert_equal Time.zone.parse("2026-09-19T08:00:00Z"), announcement(42).last_seen_updated_at

    WebMock.reset!
    stub_open_pulls(payload: moved)

    assert_equal 0, reconcile.examined
  end

  # Existing rows have no recorded state, so the first pass after the column
  # was added looks once and settles them. A bounded catch-up, not a
  # permanent cost.
  test "a row from before this was recorded is examined once" do
    announcement_row(42).update!(state: "present", last_event_at: Time.current, last_seen_updated_at: nil)
    settle(41)
    stub_open_pulls
    stub_pull(42, body: "Tightens the prose.")

    assert_equal 1, reconcile.examined
    assert_equal fixture_updated_at(42), announcement(42).last_seen_updated_at
  end

  test "an author who removed our block is never asked about again" do
    announcement_row(42).update!(state: "declined", last_event_at: 10.years.ago)
    settle(41)
    stub_open_pulls

    result = reconcile

    assert_equal 0, result.examined
    assert_not_requested :get, github_url("/repos/#{REPO}/pulls/42/files")
  end

  # Watching starts when you turn it on. A pull request untouched since then
  # would never have produced a delivery either, so announcing on it now would
  # not be replaying a missed event — it would be editing a description on a
  # promise nobody made. The subscribe screen says "new pull requests".
  test "pull requests untouched since watching started are left alone" do
    @subscription.update!(created_at: Time.utc(2026, 9, 20))
    stub_open_pulls

    result = reconcile

    assert_equal 0, result.examined
    assert_not_requested :get, github_url("/repos/#{REPO}/pulls/42/files")
  end

  test "a pass examines at most MAX_PULLS, and the rest arrive on the next one" do
    limit = Webhooks::Reconciler::MAX_PULLS
    numbers = (1..(limit + 5)).to_a
    stub_open_pulls(payload: numbers.map { |n| pull_summary(n) })
    numbers.each { |n| stub_pull(n, body: "Docs #{n}.") }

    result = reconcile

    assert_equal limit, result.examined
    assert_equal limit, PullRequestAnnouncement.where(webhook_subscription: @subscription).count
  end

  # ── Failure ────────────────────────────────────────────────────────────

  # GitHub answering the list at all is proof the account works, and it is what
  # makes the give-up clock run at the same rate on a quiet repository as on a
  # busy one.
  test "a successful pass clears a suspension" do
    @subscription.suspend!("GitHub refused this account's token")
    settle(42)
    settle(41)
    stub_open_pulls

    reconcile

    assert @subscription.reload.active?
    assert_nil @subscription.failing_since
  end

  test "an abandoned subscription is skipped without a GitHub call" do
    @subscription.abandon!("the repository is gone")

    result = reconcile

    assert_equal :skipped, result.status
    assert_not_requested :any, /api\.github\.com/
  end

  test "a signed-out subscriber is skipped without a GitHub call" do
    @subscription.user.revoke_token!

    assert_equal :skipped, reconcile.status
    assert_not_requested :any, /api\.github\.com/
  end

  # One pull request can vanish or turn private while the repository is fine.
  test "a pull request that 404s does not stop the others" do
    stub_open_pulls
    stub_github_error(:get, "/repos/#{REPO}/pulls/42/files", status: 404, message: "Not Found")
    stub_pull(41, body: "Also docs.")

    result = reconcile

    assert_equal 2, result.examined
    assert_equal 1, result.changed
    assert_equal "present", announcement(41).state
  end

  # Repository-level refusals belong to the caller, which decides what they
  # mean for the subscription — see Webhooks::ReconcileSubscriptionJob.
  test "a refused token is raised, not swallowed" do
    stub_github_error(:get, "/repos/#{REPO}/pulls", status: 401, message: "Bad credentials")

    assert_raises(Github::Unauthorized) { reconcile }
  end

  private

  def reconcile = Webhooks::Reconciler.new(subscription: @subscription).call

  def github_url(path) = "https://api.github.com#{path}"

  def stub_open_pulls(payload: github_fixture("pulls"))
    stub_github_get("/repos/#{REPO}/pulls", body: payload)
  end

  def stub_pull(number, body:)
    stub_github_get("/repos/#{REPO}/pulls/#{number}",
                    body: github_fixture("pull").merge("number" => number, "body" => body))
    stub_github_get("/repos/#{REPO}/pulls/#{number}/files", body: github_fixture("pull_files"))
    stub_request(:patch, github_url("/repos/#{REPO}/pulls/#{number}"))
      .to_return(status: 200, body: github_fixture("pull").to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  def pull_summary(number)
    github_fixture("pulls").first.merge("number" => number, "updated_at" => "2026-09-18T16:30:00Z")
  end

  def patched_body(number)
    github_request_body(:patch, "/repos/#{REPO}/pulls/#{number}").fetch("body")
  end

  def announcement_row(number)
    @subscription.pull_request_announcements.find_or_create_by!(pull_request_number: number)
  end

  def announcement(number) = announcement_row(number).reload

  # Prism has already acted on exactly the state GitHub is showing, so there is
  # nothing new to see.
  def settle(number)
    announcement_row(number).update!(state: "present", last_event_at: Time.current,
                                     last_seen_updated_at: fixture_updated_at(number))
  end

  def fixture_updated_at(number)
    payload = github_fixture("pulls").find { |pull| pull["number"] == number }
    Time.zone.parse(payload.fetch("updated_at"))
  end
end
