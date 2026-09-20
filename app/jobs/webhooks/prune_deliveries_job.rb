# frozen_string_literal: true

module Webhooks
  # Keeps the delivery log from growing forever.
  #
  # The log exists to answer "why didn't Prism do anything?" and to reject
  # replays. Neither question is ever asked about a delivery from a fortnight
  # ago: GitHub's own redelivery window is far shorter, and nothing in the app
  # reads a row that old. Without this the table is the only thing in Prism
  # that grows without bound.
  #
  # Scheduled daily in config/recurring.yml.
  class PruneDeliveriesJob < ApplicationJob
    queue_as :default

    def perform
      WebhookDelivery.expired.delete_all
    end
  end
end
