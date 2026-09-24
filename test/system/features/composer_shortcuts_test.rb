# frozen_string_literal: true

require "application_system_test_case"

# Journey 11: the composer's keyboard, which is how anyone who writes a lot of
# review comments actually submits them (PLAN.md screen 5: "Cmd/Ctrl+Enter
# submits").
#
# The interesting half is the second test. "Add single comment" is hidden
# while a pending review is open, because GitHub answers a standalone
# `addPullRequestReviewThread(pullRequestId:)` by quietly folding the comment
# into that review and handing it back as a draft (see
# review_only_actions_test.rb). The keyboard has to obey the same rule: the
# shortcut submits *the button the reviewer can see*, not whichever one the
# form happens to list first — and the form still lists the hidden single
# button. A regression there would send exactly the request the UI stopped
# offering, and nothing on screen would say so until GitHub answered with a
# draft nobody asked for.
class ComposerShortcutsTest < ApplicationSystemTestCase
  include FeatureHelpers

  OWNER = FeatureHelpers::FEATURE_OWNER
  REPO = FeatureHelpers::FEATURE_REPO
  NUMBER = FeatureHelpers::FEATURE_NUMBER
  PATH = "docs/guide.md"
  HEAD_SHA = FeatureHelpers::FEATURE_HEAD_SHA
  PR_NODE_ID = FeatureHelpers::FEATURE_PR_NODE_ID
  REVIEW_NODE_ID = "PRR_kwDOABCD12MAAAABc9BB"

  HEAD = <<~MARKDOWN
    # Guide

    This paragraph is brand new.

    And so is this second one.
  MARKDOWN

  PATCH = [
    "@@ -1,1 +1,5 @@",
    " # Guide",
    "+",
    "+This paragraph is brand new.",
    "+",
    "+And so is this second one."
  ].join("\n")

  setup do
    @user = users(:prism_dev)

    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER, files_body: files_json)
    stub_feature_mentionables(owner: OWNER, repo: REPO)
    stub_github_markdown(fixture: "markdown.html")
    stub_feature_contents(PATH, HEAD_SHA, HEAD, owner: OWNER, repo: REPO)

    sign_in_for_feature(@user)
  end

  test "Ctrl+Enter posts the comment, and Escape closes a composer without writing anything" do
    stub_feature_reviews_sequence([])
    stub_feature_review_threads([])
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)

    thread = feature_thread(node_id: "PRRT_keyboard", path: PATH, line: 3,
                            comments: [ feature_comment(node_id: "PRRC_keyboard", body: "Sent from the keyboard.") ])
    stub_github_graphql(:AddThread, data: { addPullRequestReviewThread: { thread: thread } })
    stub_feature_review_threads([ thread ])

    blocks = all("[data-testid=md-block][data-commentable=true]")
    block_id = open_composer_for(blocks.first)

    within "#composer_#{block_id}" do
      area = find("textarea", match: :first)
      area.click
      area.send_keys("Sent from the keyboard.")
      area.send_keys([ :control, :enter ])
    end

    assert_selector "[data-testid=thread]", text: "Sent from the keyboard.", wait: 5
    expect_github_received(:AddThread) do |vars|
      vars["input"]["pullRequestId"] == PR_NODE_ID && vars["input"]["body"] == "Sent from the keyboard."
    end

    # Escape is the way out of a composer opened by mistake. It must close it
    # and send nothing — a shortcut that submitted here would post half a
    # thought.
    second_id = open_composer_for(blocks.last)
    within "#composer_#{second_id}" do
      area = find("textarea", match: :first)
      area.click
      area.send_keys("Never mind.")
      area.send_keys(:escape)
    end

    assert_no_selector "#composer_#{second_id} textarea"
    assert_equal 1, github_graphql_requests.count { |request| request[:operation] == "AddThread" },
                 "Escape must not submit the composer it closes"
  end

  test "with a review open, Ctrl+Enter adds to the review rather than posting a standalone comment" do
    stub_feature_reviews_sequence([ github_fixture(:pending_review) ])
    stub_feature_review_threads([])
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    assert_selector "[data-testid=pending-count]"

    draft = feature_thread(
      node_id: "PRRT_kbdraft", path: PATH, line: 3,
      comments: [ feature_comment(node_id: "PRRC_kbdraft", body: "Into the review, from the keyboard.",
                                   state: "PENDING", author_login: "prism-dev") ]
    )
    stub_github_graphql(:AddThread, data: { addPullRequestReviewThread: { thread: draft } })
    stub_feature_review_threads([ draft ])

    block_id = open_composer_for(find("[data-testid=md-block][data-commentable=true]", match: :first))

    within "#composer_#{block_id}" do
      assert_no_selector "[data-testid=composer-submit-single]"
      area = find("textarea", match: :first)
      area.click
      area.send_keys("Into the review, from the keyboard.")
      area.send_keys([ :control, :enter ])
    end

    assert_selector "[data-testid=thread]", text: "Into the review, from the keyboard.", wait: 5
    expect_github_received(:AddThread) do |vars|
      vars["input"]["pullRequestReviewId"] == REVIEW_NODE_ID && !vars["input"].key?("pullRequestId")
    end
  end

  private

  def files_json
    [ { "filename" => PATH, "status" => "modified", "additions" => 4, "deletions" => 0, "changes" => 4,
        "patch" => PATCH, "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{PATH}" } ].to_json
  end
end
