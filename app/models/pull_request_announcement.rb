# frozen_string_literal: true

# Whether Prism's link is on a given pull request, and whether it is welcome.
#
# The pull request description is the source of truth for the *content* of our
# block: every edit reads the live body back from GitHub and splices between
# the markers. This row answers the one question the body cannot — the block
# is not there, so did we take it away, or did the author?
#
# Without that distinction, an author who deletes Prism's paragraph would see
# it reappear on their next push, and on the one after that. `declined` is a
# one-way door on purpose: erring towards silence is the only polite default
# for a bot editing someone else's prose.
#
# It also answers a cheaper question for Webhooks::Reconciler: is this pull
# request in the state we last acted on? See `last_seen_updated_at`.
class PullRequestAnnouncement < ApplicationRecord
  belongs_to :webhook_subscription

  PRESENT = "present"
  ABSENT = "absent"
  DECLINED = "declined"
  STATES = [ PRESENT, ABSENT, DECLINED ].freeze

  validates :pull_request_number, presence: true,
                                  uniqueness: { scope: :webhook_subscription_id }
  validates :state, inclusion: { in: STATES }

  def present_on_pull_request? = state == PRESENT

  def declined? = state == DECLINED

  # We believed the block was there and it is not. The author removed it, or
  # rewrote the description in a way that lost it — either way, the same
  # answer: stop offering.
  def decline!(seen_updated_at: nil)
    record!(state: DECLINED, renderable_count: 0, seen_updated_at: seen_updated_at)
  end

  def placed!(renderable_count, seen_updated_at: nil)
    record!(state: PRESENT, renderable_count: renderable_count, seen_updated_at: seen_updated_at)
  end

  def retracted!(seen_updated_at: nil)
    record!(state: ABSENT, renderable_count: 0, seen_updated_at: seen_updated_at)
  end

  def touch_event!
    update!(last_event_at: Time.current)
  end

  private

  # Writes the outcome, and survives losing a race to write it.
  #
  # Two jobs can reach the same pull request at the same moment — a delivery
  # and a reconciliation pass — and both can find no row and build one. The
  # unique index catches the loser. Losing is not an error: the winner reached
  # the same convergent decision from the same GitHub state, and an unrescued
  # raise here would fail the job, which means a link that never appears,
  # which is the thing this workstream exists to eliminate. So adopt the
  # winner's row and write the outcome onto it.
  #
  # The one thing never written over is `declined`. It is a one-way door
  # whoever put it there, and a racing pass that decided to place must not
  # undo an author's "stop".
  #
  # Jobs do not run inside an enclosing transaction, so the failed insert
  # rolls back on its own and the connection is usable for the re-read. The
  # two-error rescue mirrors WebhooksController#record_delivery: the
  # validation normally catches it first, and RecordNotUnique is what happens
  # when two inserts are genuinely simultaneous.
  def record!(state:, renderable_count:, seen_updated_at:)
    attributes = { state: state, renderable_count: renderable_count,
                   last_event_at: Time.current, last_seen_updated_at: seen_updated_at }

    update!(attributes)
    self
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => error
    raise unless lost_a_race_to_create?(error)

    winner = self.class.find_by!(webhook_subscription_id: webhook_subscription_id,
                                 pull_request_number: pull_request_number)
    return winner if winner.declined?

    winner.update!(attributes)
    winner
  end

  def lost_a_race_to_create?(error)
    return false unless new_record?
    return true if error.is_a?(ActiveRecord::RecordNotUnique)

    error.record.errors.of_kind?(:pull_request_number, :taken)
  end
end
