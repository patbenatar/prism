# frozen_string_literal: true

require "application_system_test_case"

# Journey 5: everything you can do to an existing thread once it's on the
# page — reply (immediately, and into a pending review), edit and delete your
# own comment, react and un-react, resolve and unresolve, and the affordances
# disappearing when `viewerCan*` says no.
class ThreadActionsTest < ApplicationSystemTestCase
  include FeatureHelpers

  OWNER = FeatureHelpers::FEATURE_OWNER
  REPO = FeatureHelpers::FEATURE_REPO
  NUMBER = FeatureHelpers::FEATURE_NUMBER
  PATH = "docs/guide.md"
  HEAD_SHA = FeatureHelpers::FEATURE_HEAD_SHA
  REVIEW_NODE_ID = "PRR_kwDOABCD12MAAAABc9BB"

  HEAD = <<~MARKDOWN
    # Guide

    This paragraph is brand new.
  MARKDOWN

  PATCH = [ "@@ -1,1 +1,3 @@", " # Guide", "+", "+This paragraph is brand new." ].join("\n")

  setup do
    @user = users(:prism_dev)

    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER, files_body: files_json,
                              reviews_body: [])
    stub_feature_mentionables(owner: OWNER, repo: REPO)
    stub_github_markdown(fixture: "markdown.html")
    stub_feature_contents(PATH, HEAD_SHA, HEAD, owner: OWNER, repo: REPO)

    sign_in_for_feature(@user)
  end

  test "replying immediately posts over REST using the thread's root comment" do
    root = feature_comment(node_id: "PRRC_root", database_id: 900_100, body: "Worth a second look?",
                           viewer_can_update: false, viewer_can_delete: false)
    thread = feature_thread(node_id: "PRRT_reply", path: PATH, line: 3, comments: [ root ])
    stub_feature_review_threads([ thread ])

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    assert_selector "[data-testid=thread]", text: "Worth a second look?"

    reply_comment = feature_comment(node_id: "PRRC_reply", database_id: 900_101, body: "Fixed in the next push.")
    stub_github_post("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/comments/900100/replies", fixture: :reply)
    stub_feature_review_threads([ feature_thread(node_id: "PRRT_reply", path: PATH, line: 3,
                                                 comments: [ root, reply_comment ]) ])

    within "[data-testid=thread]" do
      find("[data-testid=reply-textarea]").set("Fixed in the next push.")
      click_on "Reply"
    end

    assert_selector "[data-testid=thread]", text: "Fixed in the next push.", wait: 5
    assert_github_requested :post, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/comments/900100/replies"
  end

  test "replying into a pending review adds a draft reply over GraphQL" do
    root = feature_comment(node_id: "PRRC_root2", database_id: 900_200, body: "One nit inline.")
    thread = feature_thread(node_id: "PRRT_reply2", path: PATH, line: 3, comments: [ root ])
    stub_feature_review_threads([ thread ])
    stub_feature_reviews_sequence([ github_fixture(:pending_review) ])

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    assert_selector "[data-testid=thread]", text: "One nit inline."

    draft_reply = feature_comment(node_id: "PRRC_draftreply", database_id: 900_201,
                                  body: "Draft reply.", state: "PENDING", author_login: "prism-dev")
    stub_github_graphql(:AddThreadReply, data: { addPullRequestReviewThreadReply: { comment: draft_reply } })
    stub_feature_review_threads([ feature_thread(node_id: "PRRT_reply2", path: PATH, line: 3,
                                                 comments: [ root, draft_reply ]) ])

    within "[data-testid=thread]" do
      find("[data-testid=reply-textarea]").set("Draft reply.")
      click_on "Add to review"
    end

    assert_selector "[data-testid=thread]", text: "Draft reply.", wait: 5
    expect_github_received(:AddThreadReply) do |vars|
      vars["input"]["pullRequestReviewId"] == REVIEW_NODE_ID &&
        vars["input"]["pullRequestReviewThreadId"] == "PRRT_reply2" &&
        vars["input"]["body"] == "Draft reply."
    end
  end

  test "editing and deleting your own comment" do
    own = feature_comment(node_id: "PRRC_own", database_id: 900_300, body: "Original wording.",
                          author_login: "prism-dev", viewer_can_update: true, viewer_can_delete: true)
    thread = feature_thread(node_id: "PRRT_own", path: PATH, line: 3, comments: [ own ])
    stub_feature_review_threads([ thread ])

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    assert_selector "[data-testid=comment]", text: "Original wording."

    click_on "Edit"
    assert_selector "[data-testid=comment-edit-textarea]"

    edited = feature_comment(node_id: "PRRC_own", database_id: 900_300, body: "Edited wording.",
                             author_login: "prism-dev", viewer_can_update: true, viewer_can_delete: true)
    stub_github_graphql(:UpdateComment, data: { updatePullRequestReviewComment: { pullRequestReviewComment: edited } })

    within "[data-testid=comment-edit-form]" do
      find("[data-testid=comment-edit-textarea]").set("Edited wording.")
      click_on "Save"
    end

    assert_selector "[data-testid=comment]", text: "Edited wording.", wait: 5
    expect_github_received(:UpdateComment) do |vars|
      vars["input"]["pullRequestReviewCommentId"] == "PRRC_own" && vars["input"]["body"] == "Edited wording."
    end

    # Was split into two independent tests while _edit_form.html.erb had no
    # hidden thread_id field (a just-edited comment's Delete button would
    # submit thread_id: "" and silently fail to remove the thread) — merged
    # back now that ws-e-commenting fixed it.
    stub_github_graphql(:DeleteComment,
                        data: { deletePullRequestReviewComment: { pullRequestReviewComment: { id: "PRRC_own" } } })
    stub_feature_review_threads([])

    accept_confirm do
      click_on "Delete"
    end

    assert_no_selector "[data-testid=thread]", wait: 5
    expect_github_received(:DeleteComment) { |vars| vars["input"]["id"] == "PRRC_own" }
  end

  test "reacting and un-reacting toggles the pill" do
    comment = feature_comment(node_id: "PRRC_react", database_id: 900_400, body: "Nicely put.",
                              viewer_can_react: true, reaction_groups: [])
    thread = feature_thread(node_id: "PRRT_react", path: PATH, line: 3, comments: [ comment ])
    stub_feature_review_threads([ thread ])

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    assert_selector "[data-testid=comment]", text: "Nicely put."

    reacted = feature_comment(node_id: "PRRC_react", database_id: 900_400, body: "Nicely put.",
                              viewer_can_react: true,
                              reaction_groups: [ { content: "THUMBS_UP", viewerHasReacted: true,
                                                   reactors: { totalCount: 1 } } ])
    stub_github_graphql(:AddReaction, data: { addReaction: { subject: reacted } })

    find("[data-testid=reaction-picker] summary").click
    click_on "+1"

    assert_selector "[data-testid=comment] .reaction-pill--on", wait: 5
    expect_github_received(:AddReaction) do |vars|
      vars["input"]["subjectId"] == "PRRC_react" && vars["input"]["content"] == "THUMBS_UP"
    end

    unreacted = feature_comment(node_id: "PRRC_react", database_id: 900_400, body: "Nicely put.",
                                viewer_can_react: true,
                                reaction_groups: [ { content: "THUMBS_UP", viewerHasReacted: false,
                                                     reactors: { totalCount: 0 } } ])
    stub_github_graphql(:RemoveReaction, data: { removeReaction: { subject: unreacted } })

    within "[data-testid=comment]" do
      find("[data-testid=reaction-picker] summary").click
      click_on "+1"
    end

    assert_no_selector "[data-testid=comment] .reaction-pill--on", wait: 5
    expect_github_received(:RemoveReaction) do |vars|
      vars["input"]["subjectId"] == "PRRC_react" && vars["input"]["content"] == "THUMBS_UP"
    end
  end

  test "resolving collapses the thread, unresolving reopens it" do
    comment = feature_comment(node_id: "PRRC_resolve", database_id: 900_500, body: "All set now.")
    thread = feature_thread(node_id: "PRRT_resolve", path: PATH, line: 3, comments: [ comment ])
    stub_feature_review_threads([ thread ])

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    assert_selector "[data-testid=thread-resolve]"

    resolved = feature_thread(node_id: "PRRT_resolve", path: PATH, line: 3, comments: [ comment ],
                              resolved: true, resolved_by: { login: "prism-dev" })
    stub_github_graphql(:ResolveThread, data: { resolveReviewThread: { thread: resolved } })
    stub_feature_review_threads([ resolved ])

    click_on "Resolve"

    assert_selector "[data-testid=thread-resolved-badge]", text: /prism-dev/, wait: 5
    assert_selector "[data-testid=thread-unresolve]"
    expect_github_received(:ResolveThread) { |vars| vars["input"]["threadId"] == "PRRT_resolve" }

    unresolved = feature_thread(node_id: "PRRT_resolve", path: PATH, line: 3, comments: [ comment ], resolved: false)
    stub_github_graphql(:UnresolveThread, data: { unresolveReviewThread: { thread: unresolved } })
    stub_feature_review_threads([ unresolved ])

    click_on "Unresolve"

    assert_no_selector "[data-testid=thread-resolved-badge]", wait: 5
    assert_selector "[data-testid=thread-resolve]"
    expect_github_received(:UnresolveThread) { |vars| vars["input"]["threadId"] == "PRRT_resolve" }
  end

  test "affordances are hidden when viewerCan* says no" do
    comment = feature_comment(node_id: "PRRC_locked", database_id: 900_600, body: "Someone else's comment.",
                              author_login: "octocat", viewer_can_update: false, viewer_can_delete: false,
                              viewer_can_react: false)
    thread = feature_thread(node_id: "PRRT_locked", path: PATH, line: 3, comments: [ comment ],
                            viewer_can_resolve: false, viewer_can_unresolve: false, viewer_can_reply: false)
    stub_feature_review_threads([ thread ])

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    assert_selector "[data-testid=comment]", text: "Someone else's comment."

    within "[data-testid=comment]" do
      assert_no_selector "[data-testid=comment-edit]"
      assert_no_selector "[data-testid=comment-delete]"
    end
    within "[data-testid=thread]" do
      assert_no_selector "[data-testid=thread-resolve]"
      assert_no_selector "[data-testid=thread-unresolve]"
      # The reply box itself has no viewerCan* gate (anyone signed in can
      # reply on GitHub's own UI too) — only the "join the pending review"
      # button is gated on viewerCanReply.
      assert_selector "[data-testid=reply-form]"
      assert_no_selector "[data-testid=reply-submit-review]"
    end
  end

  private

  def files_json
    [ { "filename" => PATH, "status" => "modified", "additions" => 2, "deletions" => 0, "changes" => 2,
        "patch" => PATCH, "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{PATH}" } ].to_json
  end
end
