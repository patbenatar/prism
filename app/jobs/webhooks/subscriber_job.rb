# frozen_string_literal: true

module Webhooks
  # What every background job that acts on GitHub as a subscriber does about
  # failure. Two jobs inherit it — the delivery (the fast path) and the
  # reconciliation pass (the guarantee) — and they must agree, because a
  # subscription cannot be half suspended by one and healthy by the other.
  #
  #   RateLimited / Unavailable  transient in the moment. Back off and retry
  #                              the whole job (docs/research/github-api.md
  #                              §3.8 — retrying a rate limit too eagerly is
  #                              how an integration gets banned).
  #   Unauthorized               GitHub refused the token. Suspend, don't
  #                              kill: a token is the one thing the user can
  #                              fix, and does.
  #   Forbidden                  the account lost access, or an org withdrew
  #                              its approval of the OAuth app. Also a person's
  #                              to fix, so the same treatment — and if a
  #                              retry after a fresh sign-in is wrong about
  #                              that, it costs one GitHub call to find out.
  #   NotFound                   the repository or pull request is gone, or is
  #                              no longer visible. Never a verdict on the
  #                              subscription: one missing pull request says
  #                              nothing about the repository, and GitHub
  #                              answers 404 for "private to you" too.
  #
  # Nothing here signs anybody out: Authentication#handle_revoked_token does
  # that when a *person* hits a 401, and a background job has no session to
  # end.
  class SubscriberJob < ApplicationJob
    queue_as :default

    retry_on Github::RateLimited, wait: :polynomially_longer, attempts: 5
    retry_on Github::Unavailable, wait: :polynomially_longer, attempts: 5

    # A deleted delivery or subscription means someone unsubscribed while this
    # was queued. There is nothing to do and nothing to report.
    discard_on ActiveJob::DeserializationError
    discard_on ActiveRecord::RecordNotFound

    # The reasons Prism records on a subscription, in one place so the
    # delivery log and the subscriptions screen tell the same story whichever
    # path discovered the problem.
    TOKEN_REFUSED = "GitHub refused this account's token"
    ACCESS_REFUSED = "GitHub refused access"
    SIGNED_OUT = "the subscriber is signed out of Prism"

    private

    def refusal_detail(reason, error) = "#{reason}: #{error.user_message}"
  end
end
