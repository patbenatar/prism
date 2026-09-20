# frozen_string_literal: true

# One row per accepted webhook delivery.
#
# Its first job is replay rejection. GitHub stamps every delivery with an
# X-GitHub-Delivery GUID and repeats that GUID when a delivery is redelivered,
# so the unique index on `delivery_id` is the whole mechanism: the second
# arrival loses the insert and we answer 200 without doing anything. The
# description edit is idempotent anyway — this just stops us paying for the
# GitHub round trips to discover that.
#
# Its second job is being able to answer "why didn't Prism do anything?"
# without turning on debug logging, which is why `status` and `result` exist.
#
# Like WebhookSubscription, this is Prism's record of Prism's own behaviour,
# not a copy of GitHub's data: no payload is stored, only the event name and
# the pull request number we acted on.
class WebhookDelivery < ApplicationRecord
  belongs_to :webhook_subscription

  STATUSES = %w[accepted ignored processed failed].freeze

  validates :delivery_id, presence: true, uniqueness: true
  validates :event, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }

  # Deliveries are a debugging aid, not an archive. Nothing reads one older
  # than a fortnight, and the replay window GitHub can redeliver within is far
  # shorter than that.
  RETENTION = 14.days

  scope :expired, -> { where(created_at: ...RETENTION.ago) }

  def record!(status, result = nil)
    update!(status: status, result: result&.to_s&.truncate(1000), processed_at: Time.current)
  end
end
