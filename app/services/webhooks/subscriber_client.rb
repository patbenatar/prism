# frozen_string_literal: true

module Webhooks
  # Who Prism is when it acts on a watched repository.
  #
  # One line, in one place, on purpose. Today the answer is "the person who
  # subscribed the repository, with their OAuth token" — which is what makes
  # the edit appear on GitHub under a name the reader recognizes, and why the
  # subscribe screen asks for that consent before the button.
  #
  # The subscriber being signed out of Prism is no longer what makes this
  # fragile. Prism's OAuth App issues eight-hour tokens, and a background job
  # holds no session to notice one running out — which is exactly why
  # Github::Credentials renews inside Github::Client rather than anywhere a
  # request can reach. A client minted here at three in the morning works the
  # same as one minted a minute after a sign-in, and this method does not have
  # to know that.
  #
  # Whether this work should stop depending on a human's credential *at all*
  # — a GitHub App installation token, per
  # `docs/research/github-auth-longevity.md` — is a separate and still-open
  # question, and a much larger one now that expiry is handled. When it is
  # answered, this method is still the whole of the change on this side: the
  # two callers (Announcer, which decides what a pull request should say, and
  # Reconciler, which finds the pull requests nobody told us about) both ask
  # here rather than constructing a client of their own.
  module SubscriberClient
    def self.for(subscription) = Github::Client.new(subscription.user)
  end
end
