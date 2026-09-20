# frozen_string_literal: true

require "application_system_test_case"

# Journey 2: a single comment, posted immediately (not through a review),
# on three shapes of block — a changed paragraph (multi-line anchor), a list
# item (single line, a child block), and a table row (also a child block).
class SingleCommentTest < ApplicationSystemTestCase
  include FeatureHelpers

  OWNER = FeatureHelpers::FEATURE_OWNER
  REPO = FeatureHelpers::FEATURE_REPO
  NUMBER = FeatureHelpers::FEATURE_NUMBER
  PATH = "docs/guide.md"
  HEAD_SHA = FeatureHelpers::FEATURE_HEAD_SHA
  PR_NODE_ID = FeatureHelpers::FEATURE_PR_NODE_ID

  # Two added paragraph lines (3-4), a list gaining two items (7-8), and a
  # table gaining a row (12).
  HEAD = <<~MARKDOWN
    # Guide

    This paragraph is brand new and spans two source lines because it
    wraps, so its in-diff run is contiguous.

    - Existing item
    - Second new item
    - Third new item

    | Name | Role |
    | --- | --- |
    | Ada | Engineer |
    | Grace | Engineer |
  MARKDOWN

  PATCH = [
    "@@ -1,3 +1,13 @@",
    " # Guide",
    " ",
    "+This paragraph is brand new and spans two source lines because it",
    "+wraps, so its in-diff run is contiguous.",
    "+",
    " - Existing item",
    "+- Second new item",
    "+- Third new item",
    "+",
    " | Name | Role |",
    " | --- | --- |",
    " | Ada | Engineer |",
    "+| Grace | Engineer |"
  ].join("\n")

  setup do
    @user = users(:prism_dev)

    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER, files_body: files_json,
                              reviews_body: [])
    stub_feature_mentionables(owner: OWNER, repo: REPO)
    stub_github_markdown(fixture: "markdown.html")
    stub_feature_contents(PATH, HEAD_SHA, HEAD, owner: OWNER, repo: REPO)

    sign_in_for_feature(@user)
  end

  test "commenting on a changed paragraph posts immediately with a multi-line anchor" do
    stub_feature_review_threads([])
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)

    paragraph = find("[data-testid=md-block][data-change=added]", match: :first)

    block_id = open_composer_for(paragraph)

    # The composer no longer narrates the line it will anchor to (W4) — the
    # reviewer picked the block by clicking it. What has to be true is that
    # the anchor itself made it into the form, which the AddThread assertion
    # at the end of this test checks end to end.
    within "#composer_#{block_id}" do
      assert_no_selector "[data-composer-target=anchorNote]", text: /Lines? \d+/i
      assert_equal "4", find("[data-composer-target=line]", visible: false).value
      assert_equal "3", find("[data-composer-target=startLine]", visible: false).value
    end

    thread = feature_thread(
      node_id: "PRRT_paragraph", path: PATH, line: 4, start_line: 3,
      comments: [ feature_comment(node_id: "PRRC_paragraph", body: "Nice addition.") ]
    )
    stub_github_graphql(:AddThread, data: { addPullRequestReviewThread: { thread: thread } })
    stub_feature_review_threads([ thread ])

    within "#composer_#{block_id}" do
      area = find("textarea", match: :first)
      area.click
      area.send_keys("Nice addition.")
      click_on "Add single comment"
    end

    assert_selector "[data-testid=thread]", text: "Nice addition.", wait: 5

    expect_github_received(:AddThread) do |vars|
      input = vars["input"]
      input["pullRequestId"] == PR_NODE_ID && input["path"] == PATH &&
        input["startLine"] == 3 && input["line"] == 4 && input["side"] == "RIGHT" &&
        !input.key?("pullRequestReviewId")
    end
  end

  test "commenting on a single new list item anchors to just that line" do
    stub_feature_review_threads([])
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)

    item = find("li.md-child[data-change=added]", match: :first)
    assert_equal "true", item["data-commentable"]
    item_text = item.text

    thread = feature_thread(
      node_id: "PRRT_item", path: PATH, line: 6,
      comments: [ feature_comment(node_id: "PRRC_item", body: "Good call-out.") ]
    )
    stub_github_graphql(:AddThread, data: { addPullRequestReviewThread: { thread: thread } })
    stub_feature_review_threads([ thread ])

    block_id = comment_on_block(item, body: "Good call-out.")

    assert_selector "##{"threads_#{block_id}"} [data-testid=thread]", text: "Good call-out.", wait: 5

    expect_github_received(:AddThread) do |vars|
      input = vars["input"]
      input["path"] == PATH && input["line"].is_a?(Integer) && !input.key?("startLine") &&
        input["side"] == "RIGHT"
    end

    assert item_text.present?
  end

  test "commenting on a new table row anchors to that row's own line" do
    stub_feature_review_threads([])
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)

    row = find("tr.md-child[data-change=added]", match: :first)
    assert_equal "true", row["data-commentable"]

    thread = feature_thread(
      node_id: "PRRT_row", path: PATH, line: 13,
      comments: [ feature_comment(node_id: "PRRC_row", body: "Add a third column?") ]
    )
    stub_github_graphql(:AddThread, data: { addPullRequestReviewThread: { thread: thread } })
    stub_feature_review_threads([ thread ])

    block_id = comment_on_block(row, body: "Add a third column?")

    assert_selector "tr.md-thread-row[data-thread-row-for='#{block_id}'] [data-testid=thread]",
                    text: "Add a third column?", wait: 5

    expect_github_received(:AddThread) do |vars|
      vars["input"]["path"] == PATH && vars["input"]["line"] == 13
    end
  end

  private

  def files_json
    [ { "filename" => PATH, "status" => "modified", "additions" => 8, "deletions" => 0,
        "changes" => 8, "patch" => PATCH,
        "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{PATH}" } ].to_json
  end
end
