# frozen_string_literal: true

module Webhooks
  # Who Prism is when it acts on a watched repository.
  #
  # One line, in one place, on purpose. Today the answer is "the person who
  # subscribed the repository, with their OAuth token" — which is what makes
  # the edit appear on GitHub under a name the reader recognizes, and why the
  # subscribe screen asks for that consent before the button.
  #
  # It is also the one assumption in the webhook path that is under active
  # question: `docs/research/github-auth-longevity.md` proposes moving this
  # work to a GitHub App installation token so it stops depending on any
  # human's credential at all. That decision has not been made. When it is,
  # this method is the whole of the change on this side — the two callers
  # (Announcer, which decides what a pull request should say, and Reconciler,
  # which finds the pull requests nobody told us about) both ask here rather
  # than constructing a client of their own, so neither has to know.
  module SubscriberClient
    def self.for(subscription) = Github::Client.new(subscription.user)
  end
end
