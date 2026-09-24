# frozen_string_literal: true

require "application_system_test_case"

# Journey 4: start a review, add comments to it across two files, watch the
# tray survive a reload (rehydrated from PENDING comments in the threads
# GraphQL answers with), then submit it — and discard, in a separate test.
class PendingReviewTest < ApplicationSystemTestCase
  include FeatureHelpers

  OWNER = FeatureHelpers::FEATURE_OWNER
  REPO = FeatureHelpers::FEATURE_REPO
  NUMBER = FeatureHelpers::FEATURE_NUMBER
  PATH = "docs/guide.md"
  OTHER_PATH = "docs/appendix.md"
  HEAD_SHA = FeatureHelpers::FEATURE_HEAD_SHA
  REVIEW_ID = 80002
  REVIEW_NODE_ID = "PRR_kwDOABCD12MAAAABc9BB"

  HEAD = <<~MARKDOWN
    # Guide

    This paragraph is brand new.
  MARKDOWN

  OTHER_HEAD = <<~MARKDOWN
    # Appendix

    Another new paragraph, in a second file.
  MARKDOWN

  PATCH = [ "@@ -1,1 +1,3 @@", " # Guide", "+", "+This paragraph is brand new." ].join("\n")
  OTHER_PATCH = [ "@@ -0,0 +1,3 @@", "+# Appendix", "+", "+Another new paragraph, in a second file." ].join("\n")

  setup do
    @user = users(:prism_dev)

    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER, files_body: files_json)
    stub_feature_mentionables(owner: OWNER, repo: REPO)
    stub_github_markdown(fixture: "markdown.html")
    stub_feature_contents(PATH, HEAD_SHA, HEAD, owner: OWNER, repo: REPO)
    stub_feature_contents(OTHER_PATH, HEAD_SHA, OTHER_HEAD, owner: OWNER, repo: REPO)

    sign_in_for_feature(@user)
  end

  test "starting a review, adding comments across two files, and submitting it" do
    # No pending review and no draft threads yet. Both stubs read from this
    # shared state on every request, so they stay correct regardless of how
    # many times Page#load and the write actions each re-read them (see
    # FeatureHelpers#stub_feature_reviews_dynamic).
    state = { reviews: [], threads: [] }
    stub_feature_reviews_dynamic(state, owner: OWNER, repo: REPO, number: NUMBER)
    stub_feature_review_threads_dynamic(state)
    stub_feature_create_pending_review_dynamic(state, owner: OWNER, repo: REPO, number: NUMBER)

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)

    block = find("[data-testid=md-block][data-commentable=true]", match: :first)

    draft1 = draft_thread("1", PATH)
    stub_feature_add_thread_dynamic(state, draft1)

    block_id = open_composer_for(block)
    within "#composer_#{block_id}" do
      area = find("textarea", match: :first)
      area.click
      area.send_keys("First review comment")
      click_on "Start a review"
    end

    assert_selector "[data-testid=pending-count]", text: "1", wait: 5

    expect_github_received(:post, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews") do |body|
      body["commit_id"] == HEAD_SHA
    end
    expect_github_received(:AddThread) { |vars| vars["input"]["pullRequestReviewId"] == REVIEW_NODE_ID }

    # Switch files and add a second comment to the same pending review. The
    # file switch is a full Turbo Drive page load, so Page#load re-reads
    # `state[:threads]` for real before the second comment is ever created —
    # stub_feature_add_thread_dynamic only pushes draft2 in when its actual
    # request arrives, so that intervening read (and the tray it renders)
    # still sees just draft1.
    draft2 = draft_thread("2", OTHER_PATH)
    stub_feature_add_thread_dynamic(state, draft2)

    # The switcher is a jump menu now: both files are already on this page, so
    # this scrolls rather than navigating, and the summary follows the scroll.
    find("[data-testid=file-switcher] summary").click
    within "[data-testid=file-switcher-menu]" do
      click_on "appendix.md", match: :first
    end
    assert_current_path repo_pull_markdown_path(owner: OWNER, repo: REPO, number: NUMBER)
    assert_selector "[data-testid=file-switcher] summary", text: "appendix.md", wait: 5

    other_block = file_section(OTHER_PATH)
      .find("[data-testid=md-block][data-commentable=true]", match: :first)
    other_block_id = open_composer_for(other_block)

    within "#composer_#{other_block_id}" do
      area = find("textarea", match: :first)
      area.click
      area.send_keys("Second review comment, second file")
      # The second draft already has a pending review to join, so the label
      # switched from "Start a review" to "Add review comment".
      click_on "Add review comment"
    end

    assert_selector "[data-testid=pending-count]", text: "2", wait: 5
    expect_github_received(:AddThread) { |vars| vars["input"]["pullRequestReviewId"] == REVIEW_NODE_ID }

    # Reload: the tray survives, rehydrated purely from PENDING comments.
    visit repo_pull_markdown_path(owner: OWNER, repo: REPO, number: NUMBER,
                                  anchor: Review::Page.file_key(OTHER_PATH))
    assert_selector "[data-testid=pending-count]", text: "2", wait: 5

    # Submit as Approve.
    stub_github_post("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews/#{REVIEW_ID}/events",
                      fixture: :submitted_review)

    find("[data-testid=review-submit-open]").click
    find("[data-testid=review-event-approve]").click
    click_on "Submit review"

    assert_current_path repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)
    assert_selector "[data-testid=flash]", text: /approved/i

    expect_github_received(:post, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews/#{REVIEW_ID}/events") do |body|
      body["event"] == "APPROVE"
    end
  end

  # GitHub requires a review to carry a body OR at least one comment, not a body
  # whenever the decision is not Approve. Verified against the real API. This
  # test holds the case that used to be blocked: a reviewer who said everything
  # inline and has nothing to add as a summary.
  test "requesting changes with drafted comments and no summary goes through" do
    stub_feature_reviews_sequence([ github_fixture(:pending_review) ])
    stub_feature_review_threads([ draft_thread("1", PATH) ])
    stub_github_post("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews/#{REVIEW_ID}/events",
                      body: { id: REVIEW_ID, node_id: REVIEW_NODE_ID, state: "CHANGES_REQUESTED",
                              body: nil, user: { login: "prism-dev" },
                              html_url: "https://github.com/#{OWNER}/#{REPO}/pull/#{NUMBER}",
                              commit_id: HEAD_SHA }.to_json)

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    assert_selector "[data-testid=pending-count]", text: "1"

    find("[data-testid=review-submit-open]").click
    find("[data-testid=review-event-request-changes]").click
    click_on "Submit review"

    assert_current_path repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)
    assert_selector "[data-testid=flash]", text: /changes requested/i

    expect_github_received(:post, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews/#{REVIEW_ID}/events") do |body|
      body["event"] == "REQUEST_CHANGES" && body["body"].blank?
    end
  end

  test "requesting changes with a summary sends it" do
    stub_feature_reviews_sequence([ github_fixture(:pending_review) ])
    stub_feature_review_threads([ draft_thread("1", PATH) ])
    stub_github_post("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews/#{REVIEW_ID}/events",
                      body: { id: REVIEW_ID, node_id: REVIEW_NODE_ID, state: "CHANGES_REQUESTED",
                              body: "Needs a bit more detail.", user: { login: "prism-dev" },
                              html_url: "https://github.com/#{OWNER}/#{REPO}/pull/#{NUMBER}",
                              commit_id: HEAD_SHA }.to_json)

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    find("[data-testid=review-submit-open]").click
    find("[data-testid=review-event-request-changes]").click
    find("[data-testid=review-submit-body]").set("Needs a bit more detail.")
    click_on "Submit review"

    assert_current_path repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)
    assert_selector "[data-testid=flash]", text: /changes requested/i

    expect_github_received(:post, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews/#{REVIEW_ID}/events") do |body|
      body["event"] == "REQUEST_CHANGES" && body["body"] == "Needs a bit more detail."
    end
  end

  test "approving without a body works" do
    stub_feature_reviews_sequence([ github_fixture(:pending_review) ])
    stub_feature_review_threads([ draft_thread("1", PATH) ])
    stub_github_post("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews/#{REVIEW_ID}/events",
                      fixture: :submitted_review)

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)

    find("[data-testid=review-submit-open]").click
    find("[data-testid=review-event-approve]").click
    click_on "Submit review"

    assert_current_path repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)
    assert_selector "[data-testid=flash]", text: /approved/i
    expect_github_received(:post, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews/#{REVIEW_ID}/events") do |body|
      body["event"] == "APPROVE" && body["body"].blank?
    end
  end

  test "discarding a pending review deletes it and the tray disappears" do
    stub_feature_reviews_sequence([ github_fixture(:pending_review) ])
    stub_feature_review_threads([ draft_thread("1", PATH) ])
    stub_github_delete("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews/#{REVIEW_ID}")

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    assert_selector "[data-testid=pending-count]", text: "1"

    accept_confirm do
      click_on "Discard"
    end

    # Discarding redirects to the pull request's overview (PLAN.md's seam:
    # "review submit/discard → redirect … the page changes too much to
    # stream"), so this asserts where the reviewer actually lands and that
    # nothing pending followed them there.
    #
    # It used to assert `[data-testid=rendered-file]` here, which passed
    # against the *outgoing* review screen — Capybara found it before the
    # redirect had landed — and so said nothing about the discard at all.
    assert_current_path repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER), wait: 5
    assert_selector "[data-testid=flash]", text: /Review discarded/i
    assert_no_selector "[data-testid=pending-count]"
    assert_github_requested :delete, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews/#{REVIEW_ID}"
  end

  # The other way a review empties out: the reviewer deletes the drafts one by
  # one rather than discarding the review. GitHub keeps the (now empty)
  # pending review, so the tray stays — and `destroy` is the one write that
  # still recounts from GitHub rather than from the form, which is the part
  # only a browser can check.
  test "deleting the last draft empties the tray, and an empty review is refused before GitHub sees it" do
    state = { reviews: [ github_fixture(:pending_review) ], threads: [ deletable_draft ] }
    stub_feature_reviews_dynamic(state, owner: OWNER, repo: REPO, number: NUMBER)
    stub_feature_review_threads_dynamic(state)
    stub_delete_comment_dynamic(state)

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    assert_selector "[data-testid=pending-count]", text: "1 pending comment"

    accept_confirm { click_on "Delete" }

    assert_no_selector "[data-testid=thread]", wait: 5
    assert_selector "[data-testid=pending-count]", text: "0 pending comments"
    expect_github_received(:DeleteComment) { |vars| vars["input"]["id"] == "PRRC_deletable" }

    # Nothing drafted and no summary is not a review GitHub will take, and
    # Prism says so itself rather than spending the round trip to be told.
    find("[data-testid=review-submit-open]").click
    find("[data-testid=review-event-comment]").click
    click_on "Submit review"

    assert_selector "[data-testid=flash]", text: /a review can't be empty/i, wait: 5
    assert_github_not_requested :post, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews/#{REVIEW_ID}/events"
  end

  # COMMENT is the third event and the only one no journey submitted: a
  # review that neither approves nor blocks. Its own notice, too — "Review
  # submitted." rather than approved/changes requested.
  test "submitting as Comment sends COMMENT with the summary" do
    stub_feature_reviews_sequence([ github_fixture(:pending_review) ])
    stub_feature_review_threads([ draft_thread("1", PATH) ])
    stub_github_post("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews/#{REVIEW_ID}/events",
                      body: { id: REVIEW_ID, node_id: REVIEW_NODE_ID, state: "COMMENTED",
                              body: "Read it all; nothing blocking.", user: { login: "prism-dev" },
                              html_url: "https://github.com/#{OWNER}/#{REPO}/pull/#{NUMBER}",
                              commit_id: HEAD_SHA }.to_json)

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)

    find("[data-testid=review-submit-open]").click
    find("[data-testid=review-event-comment]").click
    find("[data-testid=review-submit-body]").set("Read it all; nothing blocking.")
    click_on "Submit review"

    assert_current_path repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)
    assert_selector "[data-testid=flash]", text: /Review submitted\./i
    assert_no_selector "[data-testid=flash]", text: /approved|changes requested/i

    expect_github_received(:post, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews/#{REVIEW_ID}/events") do |body|
      body["event"] == "COMMENT" && body["body"] == "Read it all; nothing blocking."
    end
  end

  private

  def draft_thread(key, path)
    feature_thread(
      node_id: "PRRT_draft#{key}", path: path, line: 3,
      comments: [
        feature_comment(node_id: "PRRC_draft#{key}", body: "#{'First' if key == '1'}#{'Second' if key == '2'} review comment#{', second file' if key == '2'}",
                        state: "PENDING", author_login: "prism-dev",
                        author_avatar: "https://avatars.githubusercontent.com/u/4242?v=4")
      ]
    )
  end

  # A draft the viewer is allowed to delete — the shared builder's default is
  # someone else's comment, which carries no Delete affordance.
  def deletable_draft
    feature_thread(
      node_id: "PRRT_deletable", path: PATH, line: 3,
      comments: [
        feature_comment(node_id: "PRRC_deletable", database_id: 900_900, body: "Only draft on the review",
                        state: "PENDING", author_login: "prism-dev",
                        viewer_can_update: true, viewer_can_delete: true)
      ]
    )
  end

  # Mutates `state` when the mutation actually arrives, for the same reason
  # `stub_feature_add_thread_dynamic` does: `destroy` re-reads reviewThreads
  # to recount the tray, and an eager mutation here would have that read see
  # the deletion before the request that caused it.
  def stub_delete_comment_dynamic(state)
    stub_request(:post, "#{GithubStubs::API}/graphql")
      .with { |request| graphql_operation_name(request.body) == "DeleteComment" }
      .to_return do
        state[:threads] = []
        { status: 200,
          body: { data: { deletePullRequestReviewComment: {
            pullRequestReviewComment: { id: "PRRC_deletable" }
          } } }.to_json,
          headers: GithubStubs::JSON_HEADERS }
      end
  end

  def files_json
    [
      { "filename" => PATH, "status" => "modified", "additions" => 2, "deletions" => 0, "changes" => 2,
        "patch" => PATCH, "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{PATH}" },
      { "filename" => OTHER_PATH, "status" => "added", "additions" => 3, "deletions" => 0, "changes" => 3,
        "patch" => OTHER_PATCH, "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{OTHER_PATH}" }
    ].to_json
  end
end
