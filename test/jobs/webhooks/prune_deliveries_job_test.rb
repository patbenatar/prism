# frozen_string_literal: true

require "test_helper"

class Webhooks::PruneDeliveriesJobTest < ActiveJob::TestCase
  setup { @subscription = webhook_subscriptions(:docs_site) }

  test "drops deliveries past the retention window and keeps the rest" do
    old = delivery(created_at: (WebhookDelivery::RETENTION + 1.day).ago)
    recent = delivery(created_at: 1.hour.ago)

    Webhooks::PruneDeliveriesJob.perform_now

    assert_not WebhookDelivery.exists?(old.id)
    assert WebhookDelivery.exists?(recent.id)
  end

  test "a delivery exactly at the boundary is kept" do
    edge = delivery(created_at: WebhookDelivery::RETENTION.ago + 1.minute)

    Webhooks::PruneDeliveriesJob.perform_now

    assert WebhookDelivery.exists?(edge.id)
  end

  private

  def delivery(created_at:)
    @subscription.webhook_deliveries.create!(
      delivery_id: SecureRandom.uuid, event: "pull_request", action: "opened",
      pull_request_number: 42, created_at: created_at
    )
  end
end
