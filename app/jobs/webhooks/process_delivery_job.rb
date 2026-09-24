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
  # ## Failure policy
  #
  #   RateLimited / Unavailable  transient in the moment. Back off and retry
  #                              this delivery (docs/research/github-api.md
  #                              §3.8 — retrying a rate limit too eagerly is
  #                              how an integration gets banned).
  #   Unauthorized               GitHub refused the token. **Suspend, don't
  #                              kill.** See below.
  #   Forbidden                  the account lost access, or an org has not
  #                              approved the OAuth app. Also fixable by a
  #                              person; same treatment.
  #   NotFound                   the repository or pull request is gone, or is
  #                              no longer visible to this account. Record the
  #                              delivery and leave the subscription alone —
  #                              one missing pull request says nothing about
  #                              the repository.
  #
  # ## Why a token failure suspends rather than kills
  #
  # This used to mark the subscription permanently broken, reasoning that
  # "nothing about the failure is transient". That reasoning holds for a
  # deleted repository and is wrong for a token, because a token is the one
  # thing the user *can* fix — and does, by signing in again, usually without
  # ever knowing anything was wrong. Under the old design nothing looked
  # again, and a repository stopped being watched for good over a failure that
  # had already repaired itself. It happened in production to two of three
  # subscriptions.
  #
  # So a refusal suspends. The subscription keeps acting; the next delivery
  # retries, and a success clears it. Retrying costs nothing extra — the
  # deliveries arrive whether or not we are in a position to use them — and a
  # fresh token also revives it immediately, without waiting for one (see
  # User#revive_webhook_subscriptions). Only after
  # WebhookSubscription::MAX_CONSECUTIVE_FAILURES refusals in a row do we
  # conclude nobody is coming back and stop.
  #
  # Nothing here signs anybody out: Authentication#handle_revoked_token does
  # that when a *person* hits a 401, and a background job has no session to
  # end.
  class ProcessDeliveryJob < ApplicationJob
    queue_as :default

    retry_on Github::RateLimited, wait: :polynomially_longer, attempts: 5
    retry_on Github::Unavailable, wait: :polynomially_longer, attempts: 5

    # A deleted delivery or subscription means someone unsubscribed while this
    # was queued. There is nothing to do and nothing to report.
    discard_on ActiveJob::DeserializationError
    discard_on ActiveRecord::RecordNotFound

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
      unless subscription.user&.token?
        return suspend_subscription(delivery, subscription, "the subscriber is signed out of Prism")
      end

      result = Announcer.new(
        subscription: subscription, pull_request_number: delivery.pull_request_number
      ).call

      # GitHub accepted us, so whatever was wrong before is not wrong now.
      # `skipped` is the one result that proves nothing — it means we never
      # asked GitHub anything.
      subscription.mark_active! unless result.status == :skipped

      delivery.record!("processed", "#{result.status}: #{result.detail}")
    rescue Github::Unauthorized => error
      suspend_subscription(delivery, subscription, "GitHub refused this account's token", error)
    rescue Github::Forbidden => error
      suspend_subscription(delivery, subscription, "GitHub refused access", error)
    rescue Github::NotFound => error
      # Not necessarily fatal for the subscription — a single pull request can
      # 404 while the repository is fine — so record it and leave the
      # subscription alone rather than switching it off on one bad delivery.
      delivery&.record!("failed", "not found on GitHub: #{error.message}")
    end

    private

    # Records the refusal and keeps the subscription in play. WebhookSubscription
    # decides when enough consecutive refusals mean stopping for good, so the
    # delivery log has to read the state back rather than assume it.
    def suspend_subscription(delivery, subscription, reason, error = nil)
      detail = error ? "#{reason}: #{error.user_message}" : reason
      subscription&.suspend!(detail)

      outcome =
        if subscription&.broken?
          "gave up after #{WebhookSubscription::MAX_CONSECUTIVE_FAILURES} consecutive failures"
        else
          "will retry on the next delivery"
        end

      delivery&.record!("failed", "#{detail} — #{outcome}")
    end
  end
end
