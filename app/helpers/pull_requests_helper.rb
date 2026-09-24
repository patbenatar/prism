# frozen_string_literal: true

# Reading a pull request's state, review decision, and file statuses into the
# design system's pill vocabulary. Every one of these returns a word as well as
# a color — nothing in Prism is conveyed by color alone.
module PullRequestsHelper
  # ── Browser titles ───────────────────────────────────────────────────────
  #
  # Most specific first, always. A browser truncates a title from the end
  # wherever it shows one, so whatever leads is the part that survives — and
  # the part worth surviving is the thing that tells twenty open tabs apart,
  # not the product name they all share. The layout appends "· Prism", so a
  # view supplies everything before it.
  #
  # Nothing here caps the length. Truncation is the browser's business: it is
  # the only party that knows how much room it has, and it already does the
  # job in the tab strip, the window title, the history list and the bookmark
  # bar — each at a different width. Capping here would permanently discard
  # characters from the places that *do* have room (a bookmark, a history
  # entry) to fix nothing in the one that doesn't, since a tab label is a
  # dozen characters wide and no cap short enough to rescue the repository
  # name would leave a usable title. Ordering is the fix; length is not the
  # problem.
  def page_title(*parts) = parts.compact_blank.join(" · ")

  # The title for *either* tab of a pull request — they must match, because a
  # tab strip is on screen and rewriting the window title as you move along it
  # says something changed when nothing did. Both views call this rather than
  # building a string each that happens to agree today.
  #
  # Which tab you are on is deliberately absent. It is visible on screen and
  # in the breadcrumb, so naming it here would spend the most valuable
  # characters in the title on the one thing the reader can already see.
  #
  #   pull_request_page_title(pr, owner: "acme", repo: "docs-site")
  #   → "Rewrite the getting-started guide #42 · acme/docs-site"
  def pull_request_page_title(pull_request, owner:, repo:)
    page_title("#{pull_request.title} ##{pull_request.number}", "#{owner}/#{repo}")
  end

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
