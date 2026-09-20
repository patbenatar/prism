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
  # The distinction that matters is transient versus permanent, because a
  # permanent failure retried on a schedule is how an integration gets banned
  # (docs/research/github-api.md §3.8: *"Continuing to make requests while you
  # are rate limited may result in the banning of your integration."*).
  #
  #   RateLimited / Unavailable  transient. Back off and retry.
  #   Unauthorized               the token was revoked. Nothing will fix
  #                              itself; mark the subscription broken and stop.
  #   Forbidden                  the account lost access, or an org blocked the
  #                              OAuth app. Same treatment.
  #   NotFound                   the repository or pull request is gone, or the
  #                              account can no longer see it. Record and stop.
  #
  # Nothing here signs anybody out: Authentication#handle_revoked_token does
  # that when a *person* hits a 401, and a background job has no session to
  # end. Marking the subscription broken is the job's equivalent, and the
  # subscriptions screen explains it.
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

      return delivery.record!("ignored", "subscription is broken") if subscription.broken?

      # The token can disappear between the delivery arriving and this job
      # running: any 401 anywhere in the app clears it (User#revoke_token!).
      # Acting is impossible and will stay impossible until someone signs in
      # again, so break the subscription now rather than on the next delivery.
      unless subscription.user&.token?
        return break_subscription(delivery, subscription, "the subscriber's GitHub token is gone")
      end

      result = Announcer.new(
        subscription: subscription, pull_request_number: delivery.pull_request_number
      ).call

      delivery.record!("processed", "#{result.status}: #{result.detail}")
    rescue Github::Unauthorized => error
      break_subscription(delivery, subscription, "GitHub rejected the token", error)
    rescue Github::Forbidden => error
      break_subscription(delivery, subscription, "GitHub refused access", error)
    rescue Github::NotFound => error
      # Not necessarily fatal for the subscription — a single pull request can
      # 404 while the repository is fine — so record it and leave the
      # subscription alone rather than switching it off on one bad delivery.
      delivery&.record!("failed", "not found on GitHub: #{error.message}")
    end

    private

    def break_subscription(delivery, subscription, reason, error = nil)
      detail = error ? "#{reason}: #{error.user_message}" : reason
      subscription&.mark_broken!(detail)
      delivery&.record!("failed", "#{detail} — subscription marked broken")
    end
  end
end
