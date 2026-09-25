# frozen_string_literal: true

module Webhooks
  # The scheduled sweep: one reconciliation job per subscription Prism is
  # still willing to act for.
  #
  # Deliberately a fan-out rather than a loop that does the work inline. One
  # subscription whose repository is rate limiting, or whose token GitHub has
  # started refusing, must not stop the others from being checked — and each
  # child job gets its own retry budget for the transient failures that
  # deserve one.
  #
  # Abandoned subscriptions are left out: that is what abandoning one means.
  # They come back through a credential event (a sign-in, a re-registration),
  # not through the passage of time.
  #
  # Scheduled in config/recurring.yml.
  class ReconcileAllJob < ApplicationJob
    queue_as :default

    # No jitter, deliberately. Every subscription's pass is enqueued at the
    # same instant, which at three subscriptions is three jobs and at three
    # hundred would be a two-hourly thundering herd against one worker and one
    # rate limit. Spread them then; adding scheduling machinery now would be
    # solving a problem Prism does not have.
    def perform
      WebhookSubscription.working.find_each do |subscription|
        ReconcileSubscriptionJob.perform_later(subscription.id)
      end
    end
  end
end
