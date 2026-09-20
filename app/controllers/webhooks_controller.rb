# frozen_string_literal: true

# Prism's only unauthenticated endpoint.
#
# ## Why it is safe to be unauthenticated
#
# There is no session here and no `current_user`. A delivery is authenticated
# by its HMAC: GitHub signs the raw body with a secret only GitHub and this
# database hold, and nothing at all happens until that signature verifies.
# CSRF protection is skipped because GitHub is not a browser and has no
# session cookie to be tricked into sending — the forgery this endpoint has to
# resist is a forged *signature*, which is what the HMAC is for. That is the
# only protection skipped, and this controller inherits from
# ActionController::Base rather than ApplicationController so it picks up
# nothing else by accident either.
#
# ## Why it does no work
#
# GitHub gives a webhook ten seconds and counts a slow reply as a failure;
# enough failures and it disables the hook. Everything past bookkeeping
# therefore happens in a job. The endpoint's whole job is: verify, refuse
# replays, record, enqueue, 200.
#
# ## What it trusts, and when
#
# The one awkward ordering: the secret is per subscription, so we have to know
# *which* subscription a delivery belongs to before we can verify it, and the
# only place that is written down is the payload. So the body is parsed before
# it is trusted. Webhooks::Payload reads four fields out of it and the lookup
# uses two of them as query parameters — nothing is executed, rendered, or
# written. Everything Prism later acts on is read back from GitHub with the
# subscriber's own token, never taken from the payload.
class WebhooksController < ActionController::Base
  # GitHub caps a payload at 25 MB. A pull_request event is tens of kilobytes;
  # anything approaching a megabyte is not one, and hashing it would be work
  # we do before we know the sender is real.
  MAX_BODY_BYTES = 1.megabyte

  skip_forgery_protection

  # A malformed body is the sender's problem and never worth a retry.
  rescue_from Webhooks::MalformedDelivery, with: :bad_request

  def create
    return head :content_too_large if oversized?
    return head :bad_request if delivery_id.blank? || event.blank?

    payload = Webhooks::Payload.parse(raw_body)
    subscription = find_subscription(payload)
    return head :not_found if subscription.nil?
    return head :unauthorized unless signature_valid?(subscription)

    accept(subscription, payload)
  end

  private

  # Verified, so from here on the payload can be believed.
  def accept(subscription, payload)
    subscription.touch(:last_delivery_at)

    # GitHub sends `ping` the moment a hook is created, which is how the
    # subscribe screen can say the callback works. Nothing to do but say yes.
    return head :ok if event == "ping"
    return head :ok unless event == "pull_request"

    delivery = record_delivery(subscription, payload)
    return head :ok if delivery.nil? # a replay; the first delivery already did the work

    if payload.actionable?
      Webhooks::ProcessDeliveryJob.perform_later(delivery.id)
    else
      delivery.record!("ignored", "no action taken for #{payload.action.inspect}")
    end

    head :ok
  end

  # Returns nil when this delivery id has been seen before. The unique index
  # is the mechanism, not a `find_by` first: two copies of the same delivery
  # arriving at once would both pass a check-then-insert.
  def record_delivery(subscription, payload)
    subscription.webhook_deliveries.create!(
      delivery_id: delivery_id,
      event: event,
      action: payload.action,
      pull_request_number: payload.pull_request_number
    )
  rescue ActiveRecord::RecordNotUnique
    # The unique index caught it — two copies of the same delivery arriving at
    # the same moment.
    nil
  rescue ActiveRecord::RecordInvalid => error
    # The validation caught it first, which is the ordinary case. Any other
    # validation failure is a bug and must not be mistaken for a replay.
    raise unless error.record.errors.of_kind?(:delivery_id, :taken)

    nil
  end

  def find_subscription(payload)
    return nil unless payload.repository?

    WebhookSubscription.for_repository(payload.repository_id, payload.repository_full_name)
  end

  def signature_valid?(subscription)
    Webhooks::SignatureVerifier.new(subscription.secret)
                               .valid?(payload: raw_body, signature: signature_header)
  end

  # The raw bytes, not the parsed params: the HMAC is over exactly what GitHub
  # sent, and re-serializing the parsed JSON would change whitespace and key
  # order and never match.
  def raw_body = @raw_body ||= request.raw_post

  def oversized? = request.content_length.to_i > MAX_BODY_BYTES || raw_body.bytesize > MAX_BODY_BYTES

  def delivery_id = request.headers["X-GitHub-Delivery"].presence

  def event = request.headers["X-GitHub-Event"].presence

  def signature_header = request.headers[Webhooks::SignatureVerifier::HEADER]

  def bad_request(_error) = head :bad_request
end
