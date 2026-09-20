# frozen_string_literal: true

require "test_helper"

# The public endpoint. Everything here is about what it refuses and how fast
# it says yes — the work itself is ProcessDeliveryJob's test.
class WebhooksTest < ActionDispatch::IntegrationTest
  include WebhookHelpers

  setup do
    @subscription = webhook_subscriptions(:docs_site)
    @secret = @subscription.secret
  end

  # ── Signature ──────────────────────────────────────────────────────────

  test "accepts a correctly signed delivery and queues the work" do
    assert_enqueued_with job: Webhooks::ProcessDeliveryJob do
      deliver_webhook(pull_request_event, secret: @secret)
    end

    assert_response :ok
    assert_equal 1, @subscription.webhook_deliveries.count
    assert_equal "accepted", @subscription.webhook_deliveries.sole.status
  end

  test "rejects a delivery signed with the wrong secret" do
    assert_no_enqueued_jobs do
      deliver_webhook(pull_request_event, secret: "not-the-secret")
    end

    assert_response :unauthorized
    assert_equal 0, WebhookDelivery.count
  end

  test "rejects a delivery with no signature at all" do
    assert_no_enqueued_jobs do
      deliver_webhook(pull_request_event, secret: @secret, signature: :missing)
    end

    assert_response :unauthorized
  end

  test "rejects a garbage signature header" do
    assert_no_enqueued_jobs do
      deliver_webhook(pull_request_event, secret: @secret, signature: "sha256=nonsense")
    end

    assert_response :unauthorized
  end

  # Signing a body and then posting a different one is the attack the raw-body
  # rule exists to stop.
  test "rejects a body that was swapped after signing" do
    signed_body = pull_request_event.to_json
    tampered = pull_request_event(number: 999).to_json

    deliver_webhook(tampered,
                    secret: @secret,
                    signature: webhook_signature(signed_body, @secret))

    assert_response :unauthorized
  end

  # ── Replays ────────────────────────────────────────────────────────────

  test "a redelivered payload is acknowledged but not processed twice" do
    delivery_id = SecureRandom.uuid
    payload = pull_request_event

    assert_enqueued_jobs 1 do
      deliver_webhook(payload, secret: @secret, delivery_id: delivery_id)
    end
    assert_response :ok

    assert_no_enqueued_jobs do
      deliver_webhook(payload, secret: @secret, delivery_id: delivery_id)
    end

    assert_response :ok, "a replay must still be acknowledged, or GitHub disables the hook"
    assert_equal 1, WebhookDelivery.count
  end

  test "a different delivery id for the same event is processed" do
    assert_enqueued_jobs 2 do
      deliver_webhook(pull_request_event, secret: @secret, delivery_id: SecureRandom.uuid)
      deliver_webhook(pull_request_event, secret: @secret, delivery_id: SecureRandom.uuid)
    end

    assert_equal 2, WebhookDelivery.count
  end

  # ── What it ignores ────────────────────────────────────────────────────

  test "records an unactionable action without queueing work" do
    assert_no_enqueued_jobs do
      deliver_webhook(pull_request_event(action: "labeled"), secret: @secret)
    end

    assert_response :ok
    assert_equal "ignored", @subscription.webhook_deliveries.sole.status
  end

  # Prism's own description edit produces `edited`. Acting on it would make
  # every announcement trigger another announcement, forever.
  test "ignores the edited action so our own edit cannot loop" do
    assert_no_enqueued_jobs do
      deliver_webhook(pull_request_event(action: "edited"), secret: @secret)
    end

    assert_response :ok
  end

  test "answers a ping without recording a delivery" do
    deliver_webhook(ping_event, secret: @secret, event: "ping")

    assert_response :ok
    assert_equal 0, WebhookDelivery.count
    assert @subscription.reload.last_delivery_at.present?
  end

  test "ignores an event type we never registered for" do
    assert_no_enqueued_jobs do
      deliver_webhook(pull_request_event, secret: @secret, event: "push")
    end

    assert_response :ok
  end

  test "404s a repository nobody subscribed, so GitHub eventually disables the hook" do
    deliver_webhook(pull_request_event(repo: "stranger/repo", repo_id: 1), secret: @secret)

    assert_response :not_found
  end

  # ── Malformed requests ─────────────────────────────────────────────────

  test "rejects a delivery with no delivery id" do
    deliver_webhook(pull_request_event, secret: @secret, delivery_id: nil)

    assert_response :bad_request
  end

  test "rejects a delivery with no event header" do
    deliver_webhook(pull_request_event, secret: @secret, event: nil)

    assert_response :bad_request
  end

  test "rejects a body that is not JSON" do
    deliver_webhook("not json at all", secret: @secret)

    assert_response :bad_request
  end

  test "rejects a body that is JSON but not an object" do
    deliver_webhook("[1,2,3]", secret: @secret)

    assert_response :bad_request
  end

  test "refuses an oversized body before hashing it" do
    huge = { "action" => "opened", "padding" => "x" * (WebhooksController::MAX_BODY_BYTES + 1) }.to_json

    deliver_webhook(huge, secret: @secret)

    assert_response :content_too_large
  end

  # ── Safety properties ──────────────────────────────────────────────────

  test "needs no session and never touches GitHub in the request" do
    deliver_webhook(pull_request_event, secret: @secret)

    assert_response :ok
    assert_not_requested :any, /api\.github\.com/
  end

  test "a delivery for a broken subscription is still recorded and queued" do
    broken = webhook_subscriptions(:broken)

    # The endpoint doesn't decide policy; the job does, so that "we ignored
    # this because the subscription is broken" shows up in the delivery log.
    deliver_webhook(pull_request_event(repo: broken.full_name, repo_id: broken.github_repo_id),
                    secret: broken.secret)

    assert_response :ok
    assert_equal 1, broken.webhook_deliveries.count
  end
end
