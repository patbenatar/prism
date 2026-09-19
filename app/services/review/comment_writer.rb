# frozen_string_literal: true

module Review
  # Decides create_thread vs add_thread_to_review (and reply vs reply_in_review),
  # and owns the "pending review already exists" recovery so
  # ReviewCommentsController stays thin.
  #
  # GitHub allows exactly one pending review per user per pull request.
  # Github::Client#create_pending_review already rescues the 422 that means one
  # exists and looks it up; this class rescues again around that call so a
  # second write in the same request (or a race with another tab) still finds
  # the review rather than raising.
  class CommentWriter
    MODES = %w[single review].freeze

    # The pending review this writer resolved (found or opened) in review
    # mode, if any. Public so a controller that already asked this writer to
    # ensure a pending review — and therefore already paid for a
    # `GET .../reviews` — does not pay for a second one just to render the
    # pending-review tray afterward.
    attr_reader :resolved_review

    def initialize(github:, owner:, repo:, number:)
      @github = github
      @owner = owner
      @repo = repo
      @number = number
    end

    # @return [Github::Types::ReviewThread]
    def create_thread(pull_request:, anchor:, body:, mode:)
      if review_mode?(mode)
        review = ensure_pending_review(pull_request)
        @github.add_thread_to_review(review_node_id: review.node_id, anchor: anchor, body: body)
      else
        @github.create_thread(pull_request_node_id: pull_request.node_id, anchor: anchor, body: body)
      end
    end

    # @return [Github::Types::ReviewComment]
    def reply(pull_request:, root_comment_id:, thread_node_id:, body:, mode:)
      if review_mode?(mode)
        review = ensure_pending_review(pull_request)
        @github.reply_in_review(review_node_id: review.node_id, thread_node_id: thread_node_id, body: body)
      else
        @github.reply(@owner, @repo, @number, root_comment_id, body: body)
      end
    end

    private

    # Finds the viewer's pending review, or opens one. Only called from
    # within this class (create_thread/reply in review mode) — there used to
    # be an external caller (ReviewsController#create), removed as
    # unreachable dead code by the independent review (2026-09-19, L4).
    def ensure_pending_review(pull_request)
      @resolved_review ||= @github.pending_review(@owner, @repo, @number) ||
        begin
          @github.create_pending_review(@owner, @repo, @number, commit_id: pull_request.head_sha)
        rescue Github::Unprocessable
          @github.pending_review(@owner, @repo, @number) || raise
        end
    end

    def review_mode?(mode) = mode.to_s == "review"
  end
end
