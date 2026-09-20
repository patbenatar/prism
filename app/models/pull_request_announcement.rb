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
  def decline!
    update!(state: DECLINED, renderable_count: 0, last_event_at: Time.current)
  end

  def placed!(renderable_count)
    update!(state: PRESENT, renderable_count: renderable_count, last_event_at: Time.current)
  end

  def retracted!
    update!(state: ABSENT, renderable_count: 0, last_event_at: Time.current)
  end

  def touch_event!
    update!(last_event_at: Time.current)
  end
end
