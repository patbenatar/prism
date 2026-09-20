# frozen_string_literal: true

module Webhooks
  # **Where the link goes.** This is the one object to change if Prism should
  # stop editing pull request descriptions and leave a comment instead.
  #
  # Editing someone else's description is socially loaded — plenty of teams
  # dislike a bot rewriting their words, and a comment is the more common
  # convention — so the decision is isolated here rather than spread through
  # the job. `Announcer` knows *whether* there should be a link and *what* it
  # says; a target knows *where* it lives and how to put it there, replace it,
  # and take it away.
  #
  # ## One implementation is not an accident
  #
  # A comment target was considered and deliberately declined: the
  # description is the better placement, being the first thing a reviewer
  # sees. This class stays anyway, because it records where that decision
  # lives and makes reversing it an hour's work rather than a day's. Do not
  # fold it back into `Announcer` as an unused abstraction. The full
  # reasoning, including the lost-update window the description carries and
  # a comment would not, is in docs/webhooks.md under "Where the link goes".
  #
  # A target implements three methods and nothing else:
  #
  #   current_content  → the Markdown of our block as it exists right now, or
  #                      nil if it is not there
  #   place(content)   → put (or replace) our block, returning true if the
  #                      remote actually changed
  #   retract          → remove our block, returning true if it was there
  #
  # To switch to comments, write `AnnouncementTarget::IssueComment` against
  # that interface, point `.resolve` at it, and change nothing else. It needs
  # four calls Github::Client does not have yet — list, create, update and
  # delete an issue comment on the pull request — and can reuse MarkerBlock
  # verbatim to recognize its own comment.
  class AnnouncementTarget
    # Selected by name so the choice is one string in config, not a class
    # reference scattered through the code.
    TARGETS = {
      "description" => "Webhooks::AnnouncementTarget::Description"
    }.freeze

    DEFAULT = "description"

    # `PRISM_ANNOUNCEMENT_TARGET` exists so this can be flipped without a
    # deploy once a second target is written. An unknown value falls back to
    # the default rather than breaking every delivery.
    def self.resolve
      name = ENV.fetch("PRISM_ANNOUNCEMENT_TARGET", DEFAULT)
      TARGETS.fetch(name, TARGETS.fetch(DEFAULT)).constantize
    end

    def self.build(client:, owner:, repo:, number:)
      resolve.new(client: client, owner: owner, repo: repo, number: number)
    end

    attr_reader :client, :owner, :repo, :number

    def initialize(client:, owner:, repo:, number:)
      @client = client
      @owner = owner
      @repo = repo
      @number = number
    end

    def current_content = raise NotImplementedError

    def place(_content) = raise NotImplementedError

    def retract = raise NotImplementedError
  end
end
