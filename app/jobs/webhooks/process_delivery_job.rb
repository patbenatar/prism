# frozen_string_literal: true

module Webhooks
  # Does the work the webhook endpoint refused to do in the request.
  #
  # It takes only a WebhookDelivery id. Everything else — which repository,
  # which pull request, whose token — comes from that row and its
  # subscription, and every fact about the pull request is read back from
  # GitHub. The payload never reaches this far, so a delivery cannot talk the
  # job into acting on a repository nobody subscribed.
  #
  # The failure policy — which GitHub refusals suspend, which retry, which are
  # recorded and forgotten — lives in SubscriberJob, because the
  # reconciliation pass has to make exactly the same judgements about exactly
  # the same subscription.
  #
  # ## This is the fast path, not the guarantee
  #
  # A delivery that never arrives, or arrives while the token is refused, used
  # to be lost outright: the WebhookDelivery row sat at `failed` and nothing
  # ever looked at that pull request again. Webhooks::Reconciler is what goes
  # back for it, on a schedule and on a fresh sign-in. So this job can be what
  # it should be — the quick way to find out, not the only way.
  #
  # ## Why a token failure suspends rather than kills
  #
  # This used to mark the subscription permanently broken, reasoning that
  # "nothing about the failure is transient". That reasoning holds for a
  # deleted repository and is wrong for a token, because a token is the one
  # thing the user *can* fix — and does, by signing in again, usually without
  # ever knowing anything was wrong. Under the old design nothing looked
  # again, and a repository stopped being watched for good over a failure that
  # had already repaired itself. It happened in production.
  #
  # So a refusal suspends. The subscription keeps acting; the next delivery
  # retries, and a success clears it. A fresh token revives it immediately
  # (see User#revive_webhook_subscriptions!) and takes a reconciliation pass
  # with it. Only once it has been failing for longer than
  # WebhookSubscription::GIVE_UP_AFTER — a measure of time, not of how many
  # deliveries the repository happened to produce — do we conclude nobody is
  # coming back and stop.
  class ProcessDeliveryJob < SubscriberJob
    def perform(webhook_delivery_id)
      delivery = WebhookDelivery.find(webhook_delivery_id)
      subscription = delivery.webhook_subscription

      # `broken` now means we gave up for good. `suspended` deliberately falls
      # through: retrying is the whole mechanism by which it recovers.
      return delivery.record!("ignored", "subscription was abandoned after repeated failures") if subscription.broken?

      # The token can disappear between the delivery arriving and this job
      # running: any 401 anywhere in the app clears it (User#revoke_token!).
      # Nothing can be done until the user signs in again — but they very well
      # might, so this suspends rather than ends it.
      return suspend_subscription(delivery, subscription, SIGNED_OUT) unless subscription.user&.token?

      result = Announcer.new(
        subscription: subscription, pull_request_number: delivery.pull_request_number
      ).call

      # GitHub accepted us, so whatever was wrong before is not wrong now.
      # `skipped` is the one result that proves nothing — it means we never
      # asked GitHub anything.
      subscription.mark_active! unless result.status == :skipped

      delivery.record!("processed", "#{result.status}: #{result.detail}")
    rescue Github::Unauthorized => error
      suspend_subscription(delivery, subscription, TOKEN_REFUSED, error)
    rescue Github::Forbidden => error
      suspend_subscription(delivery, subscription, ACCESS_REFUSED, error)
    rescue Github::NotFound => error
      # Not necessarily fatal for the subscription — a single pull request can
      # 404 while the repository is fine — so record it and leave the
      # subscription alone rather than switching it off on one bad delivery.
      delivery&.record!("failed", "not found on GitHub: #{error.message}")
    end

    private

    # Records the refusal and keeps the subscription in play. WebhookSubscription
    # decides when a run of refusals has gone on long enough to mean stopping
    # for good, so the delivery log has to read the state back rather than
    # assume it.
    def suspend_subscription(delivery, subscription, reason, error = nil)
      detail = error ? refusal_detail(reason, error) : reason
      subscription&.suspend!(detail)

      outcome =
        if subscription&.broken?
          "gave up after #{WebhookSubscription::GIVE_UP_AFTER.inspect} of failures"
        else
          "will retry on the next delivery or reconciliation pass"
        end

      delivery&.record!("failed", "#{detail} — #{outcome}")
    end
  end
end
