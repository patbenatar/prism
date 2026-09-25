# frozen_string_literal: true

module Webhooks
  # One reconciliation pass over one subscription. See Webhooks::Reconciler
  # for what a pass does and what it costs; this is only the failure policy
  # and the plumbing around it.
  #
  # Enqueued from three places, all of them "something just changed that could
  # have let deliveries go missing":
  #
  #   - Webhooks::ReconcileAllJob, on a schedule (config/recurring.yml). The
  #     one that needs no trigger at all, and the one that makes the give-up
  #     clock run at the same rate on a quiet repository as on a busy one.
  #   - User#revive_webhook_subscriptions!, on a fresh sign-in. Reviving a
  #     subscription only means the *next* event will be handled; the events
  #     refused while the token was dead are still missing, and this is what
  #     goes back for them.
  #   - Webhooks::Registrar#re_register, when a moved callback URL is pointed
  #     back at Prism. By definition nothing was arriving until then.
  class ReconcileSubscriptionJob < SubscriberJob
    def perform(webhook_subscription_id)
      subscription = WebhookSubscription.find(webhook_subscription_id)

      # Abandoned is abandoned: a scheduled pass must not quietly resurrect a
      # subscription Prism gave up on. Only a credential event does that, and
      # it does it by clearing the status first (see
      # WebhookSubscription#revive_after_new_token!).
      return if subscription.broken?

      # Recorded rather than skipped, so the clock runs on a subscription that
      # cannot work for want of a token — exactly as it does when a delivery
      # discovers the same thing.
      return subscription.suspend!(SIGNED_OUT) unless subscription.user&.token?

      Reconciler.new(subscription: subscription).call
    rescue Github::Unauthorized => error
      subscription.suspend!(refusal_detail(TOKEN_REFUSED, error))
    rescue Github::Forbidden => error
      subscription.suspend!(refusal_detail(ACCESS_REFUSED, error))
    rescue Github::NotFound
      # The repository is gone, renamed, or no longer visible to this account,
      # and nothing about a single 404 tells us which. Leave the subscription
      # alone; if it really is gone the hook died with it and the deliveries
      # stop on their own.
      nil
    end
  end
end
