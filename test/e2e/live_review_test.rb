# frozen_string_literal: true

require "test_helper"
require_relative "e2e_helper"

# Opt-in, live-GitHub tier. Skipped entirely unless E2E_GITHUB_TOKEN, E2E_REPO
# ("owner/name") and E2E_PR are set — see docs/testing.md.
#
# Everything else in this suite stubs GitHub with WebMock; this file is the
# one exception, because two things can only be proven against the real API:
# the multi-line anchor rule (`start_line..line` accepted only when every line
# in the range is genuinely in the diff) and the pending-review flow
# end-to-end (GitHub permits exactly one per user per pull request, and
# `addPullRequestReviewThread(pullRequestReviewId:)` really does draft rather
# than post).
#
# Drives `Github::Client` + the same `Review::*` value objects the app uses —
# never the browser — so a failure here points at the client/anchor logic,
# not at Turbo or Stimulus. Every write this test makes is undone in an
# `ensure`; it never submits a review (an unsubmitted, deleted pending review
# leaves no trace on the pull request).
class LiveReviewTest < ActiveSupport::TestCase
  include E2eHelper

  setup do
    skip_unless_e2e_configured!

    # The one deliberate exception to "GitHub is always stubbed" — this tier
    # exists specifically to hit the real API.
    WebMock.allow_net_connect!

    @owner, @repo = e2e_owner_and_repo
    @number = e2e_pr_number
    @github = e2e_client
  end

  teardown do
    WebMock.disable_net_connect!(allow_localhost: true) if e2e_configured?
  end

  test "draft threads with a multi-line and a single-line anchor, plus a reply, on a pending review" do
    pull_request = @github.pull_request(@owner, @repo, @number)
    files = @github.pull_request_files(@owner, @repo, @number, head_sha: pull_request.head_sha)
    markdown_file = files.find(&:markdown?)
    assert markdown_file, "E2E_PR needs at least one Markdown file for this to prove anything"
    assert markdown_file.patch?, "E2E_PR's first Markdown file has no diff to anchor to — pick a PR with a real edit"

    source = @github.file_content(@owner, @repo, markdown_file.path, ref: pull_request.head_sha)
    blocks = Markdown::Document.parse(source).blocks
    line_sets = Diff::Patch.parse(markdown_file.patch)

    _, multi_line_anchor = e2e_find_commentable(blocks, line_sets, markdown_file.path, &:multi_line?)
    _, single_line_anchor = e2e_find_commentable(blocks, line_sets, markdown_file.path) { |a| !a.multi_line? }

    assert multi_line_anchor, "E2E_PR needs a block with >= 2 contiguous in-diff lines for the multi-line case"
    assert single_line_anchor, "E2E_PR needs a block anchorable to a single line"

    review = nil
    begin
      review = @github.create_pending_review(@owner, @repo, @number, commit_id: pull_request.head_sha)
      assert_equal "PENDING", review.state

      multi_thread = @github.add_thread_to_review(
        review_node_id: review.node_id, anchor: multi_line_anchor,
        body: "Prism e2e test — multi-line draft, deleted automatically. Safe to ignore."
      )
      single_thread = @github.add_thread_to_review(
        review_node_id: review.node_id, anchor: single_line_anchor,
        body: "Prism e2e test — single-line draft, deleted automatically. Safe to ignore."
      )
      @github.reply_in_review(
        review_node_id: review.node_id, thread_node_id: single_thread.node_id,
        body: "Prism e2e test — draft reply, deleted automatically. Safe to ignore."
      )

      threads = @github.review_threads(@owner, @repo, @number).threads
      multi = threads.find { |t| t.node_id == multi_thread.node_id }
      single = threads.find { |t| t.node_id == single_thread.node_id }
      assert multi, "the multi-line draft thread didn't come back from reviewThreads"
      assert single, "the single-line draft thread didn't come back from reviewThreads"

      # The rule under test: startLine..line is accepted, and both ends are
      # exactly the anchor Review::AnchorResolver computed from the real diff.
      assert_equal "PENDING", multi.comments.first.state
      assert_equal multi_line_anchor.line, multi.line
      assert_equal multi_line_anchor.start_line, multi.start_line
      assert_equal "RIGHT", multi.diff_side

      assert_equal "PENDING", single.comments.first.state
      assert_equal single_line_anchor.line, single.line
      assert_nil single.start_line
      assert_equal 2, single.comments.size, "the draft reply should be the thread's second comment"

      # The rule the research couldn't verify without hitting the real API: a
      # line outside every hunk 422s, and Github::Client translates that into
      # Github::LineNotCommentable rather than a generic Unprocessable.
      outside_anchor = Review::Anchor.line(path: markdown_file.path, line: e2e_impossible_line(source), side: :right)
      assert_raises(Github::LineNotCommentable) do
        @github.add_thread_to_review(review_node_id: review.node_id, anchor: outside_anchor,
                                     body: "Prism e2e test — should never post, GitHub must 422 this.")
      end
    ensure
      @github.delete_pending_review(@owner, @repo, @number, review.id) if review
    end
  end

  test "a file-level comment can be created and deleted" do
    pull_request = @github.pull_request(@owner, @repo, @number)
    files = @github.pull_request_files(@owner, @repo, @number, head_sha: pull_request.head_sha)
    markdown_file = files.find(&:markdown?)
    assert markdown_file, "E2E_PR needs at least one Markdown file for this to prove anything"

    thread = @github.create_thread(
      pull_request_node_id: pull_request.node_id,
      anchor: Review::Anchor.file(markdown_file.path),
      body: "Prism e2e test — file-level comment, deleted automatically. Safe to ignore."
    )

    begin
      assert_equal "FILE", thread.subject_type
      assert_equal 1, thread.comments.size
    ensure
      @github.delete_comment(thread.comments.first.node_id)
    end
  end
end
