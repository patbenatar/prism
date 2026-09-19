# frozen_string_literal: true

# Reading a pull request's state, review decision, and file statuses into the
# design system's pill vocabulary. Every one of these returns a word as well as
# a color — nothing in Prism is conveyed by color alone.
module PullRequestsHelper
  # The PR's headline state. Draft outranks open, because a draft is not asking
  # to be reviewed yet, and merged outranks closed.
  #
  #   pull_request_state(pr) → [:merged, "Merged", "pill-brand"]
  def pull_request_state(pull_request)
    if pull_request.merged?
      [ :merged, "Merged", "pill-brand" ]
    elsif pull_request.state == "closed"
      [ :closed, "Closed", "pill-removed" ]
    elsif pull_request.draft?
      [ :draft, "Draft", "pill-neutral" ]
    else
      [ :open, "Open", "pill-added" ]
    end
  end

  # Derives the review decision from the reviews GitHub returned. GitHub's own
  # `reviewDecision` is GraphQL-only and not on our PullRequest value object, so
  # we reduce the review list the same way GitHub's UI does: the latest
  # submitted review per author wins, and comment-only reviews don't count as a
  # decision.
  #
  #   review_decision([...]) → [:approved, "Approved", "pill-added"]
  DECIDING_STATES = %w[APPROVED CHANGES_REQUESTED DISMISSED].freeze

  def review_decision(reviews)
    latest = Array(reviews)
      .reject { |review| review.state == "PENDING" }
      .select { |review| DECIDING_STATES.include?(review.state) }
      .group_by { |review| review.author&.login }
      .values
      .filter_map { |for_author| for_author.max_by { |review| review.submitted_at.to_s } }
      .reject { |review| review.state == "DISMISSED" }

    if latest.any? { |review| review.state == "CHANGES_REQUESTED" }
      [ :changes_requested, "Changes requested", "pill-removed" ]
    elsif latest.any? { |review| review.state == "APPROVED" }
      [ :approved, "Approved", "pill-added" ]
    else
      [ :review_required, "Review required", "pill-neutral" ]
    end
  end

  # How a single review reads in a reviewer summary row.
  def review_state_label(state)
    case state
    when "APPROVED"          then [ "Approved", "pill-added" ]
    when "CHANGES_REQUESTED" then [ "Requested changes", "pill-removed" ]
    when "COMMENTED"         then [ "Commented", "pill-neutral" ]
    when "DISMISSED"         then [ "Dismissed", "pill-resolved" ]
    when "PENDING"           then [ "Pending", "pill-pending" ]
    else [ state.to_s.humanize, "pill-neutral" ]
    end
  end

  # A changed file's status, in the spectrum's language.
  def file_status_label(status)
    case status
    when "added"    then [ "Added", "pill-added" ]
    when "removed"  then [ "Removed", "pill-removed" ]
    when "renamed"  then [ "Renamed", "pill-neutral" ]
    when "copied"   then [ "Copied", "pill-neutral" ]
    else [ "Modified", "pill-modified" ]
    end
  end

  # Splits "docs/guides/setup.md" into its directory and basename so a file row
  # can weight the filename and mute the path leading to it.
  def split_path(path)
    directory, _, basename = path.to_s.rpartition("/")
    [ directory.presence&.+("/"), basename ]
  end

  # The tab set on the pull request list. Returns [label, state, active?].
  def pull_request_tabs(current_state)
    %w[open closed all].map do |state|
      [ state.capitalize, state, state == current_state ]
    end
  end
end
