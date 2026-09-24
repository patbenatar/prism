# frozen_string_literal: true

# Submitting and discarding the viewer's pending review.
#
# The pending review lives on GitHub, never in Prism (PLAN.md principle 1):
# `submit` and `destroy` hand off to REST. Both change the page enough that a
# redirect, not a Turbo Stream, is the right response — see PLAN.md "Phase 2
# seam".
#
# There is deliberately no `create` here. PLAN.md's route
# (`post "reviews", to: "reviews#create"`) and Review::CommentWriter's
# `ensure_pending_review` both once framed this as "start a review before
# writing your first comment," but nothing ever links or posts to it — the
# composer's own "Start a review" button posts straight to
# ReviewCommentsController#create with `commit=review`, which opens the
# pending review as a side effect of the first comment, and the tray only
# exists once one is already open. The independent review (2026-09-19, L4)
# flagged the action as unreachable dead code; removed rather than wired to
# a real affordance, since the composer already covers what it would do.
class ReviewsController < ApplicationController
  before_action :set_scope

  # Both actions redirect on success, so they redirect on failure too — there
  # is no fragment to answer in place with, and the reviewer's own words are
  # not at stake here the way they are in a composer.
  #
  # NotFound/Forbidden/Unavailable are on this list rather than handled by
  # GithubErrorHandling: a pull request deleted under an open review, a token
  # that lost its access, or GitHub falling over are all things a reviewer
  # meets at exactly the moment they press Submit, and none of them was
  # rescued at all before — every one was a 500 painted over the review
  # screen by Turbo.
  rescue_from Github::Unprocessable, Github::RateLimited, Github::NotFound, Github::Forbidden,
              Github::Unavailable, with: :handle_review_error

  # POST .../reviews/:id/submit — :id is the review's REST id.
  #
  # params: event (APPROVE|REQUEST_CHANGES|COMMENT), body.
  def submit
    event = params[:event].to_s.upcase
    body = params[:body].presence

    return redirect_to file_path, alert: "Choose Approve, Request changes, or Comment." unless EVENTS.include?(event)

    # GitHub's rule is not "a body unless approving", which is what this used to
    # enforce and what the panel used to say. A review has to carry *something*:
    # a body OR at least one comment. Verified against the real API — submitting
    # COMMENT with no body and no comments is rejected with "You need to leave a
    # comment indicating the requested changes", while the same submission with
    # one draft comment attached succeeds. Requiring a body from a reviewer who
    # has just written five inline comments blocked a perfectly ordinary review.
    #
    # The count comes from the tray, which already tracks it without a round
    # trip. When it is missing we do not guess: GitHub validates this anyway and
    # says so clearly, and handle_review_error surfaces its words.
    drafted = params[:pending_count].presence&.to_i
    if body.blank? && drafted&.zero?
      return redirect_to file_path,
                         alert: "Add a summary, or a comment on a line — a review can't be empty."
    end

    review = github.submit_review(@owner, @repo, @number, params[:id], event: event, body: body)

    redirect_to repo_pull_path(owner: @owner, repo: @repo, number: @number), notice: submit_notice(review)
  end

  # DELETE .../reviews/:id — :id is the review's REST id.
  def destroy
    github.delete_pending_review(@owner, @repo, @number, params[:id])

    redirect_to file_path, notice: "Review discarded."
  end

  private

  def set_scope
    @owner = params[:owner]
    @repo = params[:repo]
    @number = params[:number].to_i
  end

  EVENTS = %w[APPROVE REQUEST_CHANGES COMMENT].freeze

  def submit_notice(review)
    case review.state
    when "APPROVED" then "Review submitted: approved."
    when "CHANGES_REQUESTED" then "Review submitted: changes requested."
    else "Review submitted."
    end
  end

  def file_path
    repo_pull_path(owner: @owner, repo: @repo, number: @number)
  end

  def handle_review_error(error)
    redirect_to file_path, alert: error.user_message
  end
end
