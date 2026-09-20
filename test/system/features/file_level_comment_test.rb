# frozen_string_literal: true

require "application_system_test_case"

# Journey 3: a block that sits outside the diff. GitHub can't anchor a line
# comment to it, so Prism explains that in the composer and posts it as a
# file-level comment quoting the block, with a permalink into the block's own
# lines.
class FileLevelCommentTest < ApplicationSystemTestCase
  include FeatureHelpers

  OWNER = FeatureHelpers::FEATURE_OWNER
  REPO = FeatureHelpers::FEATURE_REPO
  NUMBER = FeatureHelpers::FEATURE_NUMBER
  PATH = "docs/guide.md"
  HEAD_SHA = FeatureHelpers::FEATURE_HEAD_SHA
  PR_NODE_ID = FeatureHelpers::FEATURE_PR_NODE_ID

  # Only lines 1-4 are ever touched by the patch; "## Untouched section" and
  # its paragraph (lines 6-8) sit well outside every hunk.
  HEAD = <<~MARKDOWN
    # Guide

    This paragraph is brand new.

    ## Untouched section

    Nothing about this paragraph changed, so it is outside the diff and
    GitHub has no line here to anchor a comment to.
  MARKDOWN

  PATCH = [
    "@@ -1,1 +1,3 @@",
    " # Guide",
    "+",
    "+This paragraph is brand new."
  ].join("\n")

  setup do
    @user = users(:prism_dev)

    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER, files_body: files_json,
                              reviews_body: [])
    stub_feature_mentionables(owner: OWNER, repo: REPO)
    stub_github_markdown(fixture: "markdown.html")
    stub_feature_contents(PATH, HEAD_SHA, HEAD, owner: OWNER, repo: REPO)
    stub_feature_review_threads([])

    sign_in_for_feature(@user)
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
  end

  test "a block outside the diff explains itself and posts as a file-level comment" do
    heading = find("[data-testid=md-block][data-block-type=heading]", text: "Untouched section")
    assert_equal "false", heading["data-commentable"]

    block_id = open_composer_for(heading)

    within "#composer_#{block_id}" do
      assert_selector "[data-composer-target=anchorNote]", text: /isn't part of the PR diff/i
      # filePreviewNote starts `hidden` in the template; composer#open clears
      # that only in file-comment mode, so its presence here is the signal.
      assert_selector "[data-composer-target=filePreviewNote]",
                      text: /Will be posted as a file-level comment quoting this block/
    end

    draft = feature_thread(
      node_id: "PRRT_file", path: PATH, subject_type: "FILE",
      comments: [ feature_comment(node_id: "PRRC_file", body: "> ## Untouched section\n\nWorth expanding this.") ]
    )
    stub_github_graphql(:AddThread, data: { addPullRequestReviewThread: { thread: draft } })
    stub_feature_review_threads([ draft ])

    within "#composer_#{block_id}" do
      area = find("textarea", match: :first)
      area.click
      area.send_keys("Worth expanding this.")
      click_on "Add single comment"
    end

    # A file-level comment appears at the top of its own file's section,
    # not under the block whose composer happened to create it.
    assert_selector "##{file_threads_id(PATH)} [data-testid=thread]",
                    text: "Worth expanding this.", wait: 5

    expect_github_received(:AddThread) do |vars|
      input = vars["input"]
      body = input["body"]
      input["pullRequestId"] == PR_NODE_ID && input["subjectType"] == "FILE" &&
        !input.key?("line") && !input.key?("startLine") &&
        body.include?("> Untouched section") &&
        body.match?(%r{https://github\.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{Regexp.escape(PATH)}#L\d+(-L\d+)?}) &&
        body.end_with?("Worth expanding this.")
    end
  end

  private

  def files_json
    [ { "filename" => PATH, "status" => "modified", "additions" => 2, "deletions" => 0,
        "changes" => 2, "patch" => PATCH,
        "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{PATH}" } ].to_json
  end
end
