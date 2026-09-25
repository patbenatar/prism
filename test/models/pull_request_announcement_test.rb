# frozen_string_literal: true

require "test_helper"

class PullRequestAnnouncementTest < ActiveSupport::TestCase
  setup { @subscription = webhook_subscriptions(:docs_site) }

  test "recording an outcome stores what Prism saw alongside what it did" do
    seen = Time.zone.parse("2026-09-18T16:30:00Z")

    announcement = @subscription.announcement_for(42)
    announcement.placed!(3, seen_updated_at: seen)

    stored = @subscription.pull_request_announcements.find_by!(pull_request_number: 42)

    assert_equal "present", stored.state
    assert_equal 3, stored.renderable_count
    assert_equal seen, stored.last_seen_updated_at
    assert stored.last_event_at.present?
  end

  # ── Losing the race to create the row ──────────────────────────────────

  # A delivery and a reconciliation pass can reach the same pull request at
  # the same moment, and both can find no row and build one. Before this, the
  # loser raised out of the job — which means a link that never appears, which
  # is the thing this whole workstream exists to eliminate.
  test "losing the race to create the row records the outcome anyway" do
    ours = @subscription.announcement_for(42)
    theirs = @subscription.announcement_for(42)
    theirs.retracted!

    result = ours.placed!(2)

    stored = @subscription.pull_request_announcements.find_by!(pull_request_number: 42)

    assert_equal "present", stored.state
    assert_equal 2, stored.renderable_count
    assert_equal stored, result
    assert_equal 1, @subscription.pull_request_announcements.count
  end

  # `declined` is a one-way door whoever put it there. A pass that decided to
  # place, racing a pass that discovered the author had deleted the block,
  # must not undo the author's answer.
  test "a racing outcome never writes over declined" do
    ours = @subscription.announcement_for(42)
    theirs = @subscription.announcement_for(42)
    theirs.decline!

    ours.placed!(2)

    assert_equal "declined", @subscription.pull_request_announcements.find_by!(pull_request_number: 42).state
  end

  # The rescue is for losing a create, not for papering over anything else a
  # save can refuse.
  test "an ordinary validation failure still raises" do
    announcement = @subscription.announcement_for(42)
    announcement.pull_request_number = nil

    assert_raises(ActiveRecord::RecordInvalid) { announcement.placed!(1) }
  end
end
