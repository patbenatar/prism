# frozen_string_literal: true

module Webhooks
  # Decides what Prism should be saying on a pull request, and makes it so.
  #
  # The rule is a single convergent one, not a list of event handlers: *the
  # link is present exactly when the pull request contains at least one
  # renderable Markdown file, unless the author has removed it.* Every event —
  # opened, reopened, pushed to, marked ready — runs the same comparison, so a
  # redelivery, a second push and a delivery processed out of order all land on
  # the same answer. Nothing here asks "what changed?"; it asks "what should be
  # true?" and fixes the difference.
  #
  # Where the link goes is not this object's business. See AnnouncementTarget.
  class Announcer
    Result = Data.define(:status, :detail, :renderable_count) do
      def changed? = %i[placed retracted].include?(status)
    end

    attr_reader :subscription, :pull_request_number, :seen_updated_at

    # `seen_updated_at` is GitHub's `updated_at` for this pull request as the
    # caller observed it, when the caller happens to know. Recorded with the
    # outcome so Webhooks::Reconciler can tell "this is the state we already
    # acted on" from "something has happened since" without comparing two
    # machines' clocks. The delivery path does not know it and does not need
    # to — it passes nil, and the next reconciliation pass fills it in.
    def initialize(subscription:, pull_request_number:, seen_updated_at: nil)
      @subscription = subscription
      @pull_request_number = pull_request_number
      @seen_updated_at = seen_updated_at
    end

    def call
      return result(:skipped, "subscription is #{subscription.status}") unless subscription.actable?

      announcement = subscription.announcement_for(pull_request_number)
      return result(:skipped, "author removed Prism's block") if announcement.declined?

      if removed_by_author?(announcement)
        announcement.decline!(seen_updated_at: seen_updated_at)
        return result(:declined, "author removed Prism's block")
      end

      renderable.any? ? place(announcement) : retract(announcement)
    end

    private

    # `seen_updated_at` is deliberately what the caller saw *before* this run,
    # even when the run wrote. Our own PATCH moves GitHub's `updated_at` to a
    # value we would have to spend a call to learn, so recording the old one
    # simply means the next reconciliation pass looks at this pull request once
    # more, finds `unchanged`, and records the settled value then. One extra
    # examination per pull request we write to, in exchange for never claiming
    # to have seen a state we did not see.
    def place(announcement)
      changed = target.place(link.markdown(file_count: renderable.size))
      announcement.placed!(renderable.size, seen_updated_at: seen_updated_at)

      changed ? result(:placed, "link written") : result(:unchanged, "link already correct")
    end

    def retract(announcement)
      changed = target.retract
      announcement.retracted!(seen_updated_at: seen_updated_at)

      changed ? result(:retracted, "no renderable Markdown left") : result(:unchanged, "no renderable Markdown")
    end

    # We recorded that the block was there and it is not. Somebody took it out,
    # and it was not us — Prism only removes it when the Markdown is gone, and
    # that path records the removal.
    def removed_by_author?(announcement)
      announcement.present_on_pull_request? && target.current_content.nil?
    end

    # "Renderable" means a Markdown file that still exists on the head side. A
    # removed .md file has nothing to render, and a pull request whose only
    # Markdown change is a deletion should not advertise a review screen with
    # nothing on it.
    def renderable
      @renderable ||= client.pull_request_files(subscription.owner, subscription.name, pull_request_number)
                            .select { |file| file.markdown? && !file.removed? }
    end

    def target
      @target ||= AnnouncementTarget.build(
        client: client, owner: subscription.owner, repo: subscription.name, number: pull_request_number
      )
    end

    def link
      @link ||= ReviewLink.new(owner: subscription.owner, repo: subscription.name, number: pull_request_number)
    end

    # As the subscriber, always. The edit shows up on GitHub under their name,
    # which is the whole point of asking them to subscribe rather than running
    # Prism as a bot account nobody recognizes. SubscriberClient is where that
    # answer lives, and the one thing a move to a GitHub App would replace.
    def client = @client ||= SubscriberClient.for(subscription)

    def result(status, detail) = Result.new(status: status, detail: detail, renderable_count: @renderable&.size || 0)
  end
end
