# frozen_string_literal: true

require "application_system_test_case"

# Journey 8: @-mention autocomplete (collaborators + org members) and the
# composer's Write/Preview tabs, backed by GitHub's own /markdown endpoint.
class MentionsAndPreviewTest < ApplicationSystemTestCase
  include FeatureHelpers

  OWNER = FeatureHelpers::FEATURE_OWNER
  REPO = FeatureHelpers::FEATURE_REPO
  NUMBER = FeatureHelpers::FEATURE_NUMBER
  PATH = "docs/guide.md"
  HEAD_SHA = FeatureHelpers::FEATURE_HEAD_SHA

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
    stub_feature_contents(PATH, HEAD_SHA, HEAD, owner: OWNER, repo: REPO)
    stub_feature_review_threads([])

    sign_in_for_feature(@user)
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
  end

  test "typing @oc opens the mention listbox, and arrow+enter inserts the login" do
    block = find("[data-testid=md-block][data-commentable=true]", match: :first)
    block_id = open_composer_for(block)

    within "#composer_#{block_id}" do
      area = find("textarea", match: :first)
      area.click
      area.send_keys("Nice work @oc")

      assert_selector "[role=listbox] [role=option]", text: /octocat/i, wait: 5

      area.send_keys(:down)
      area.send_keys(:enter)

      assert_field type: "textarea", with: "Nice work @octocat ", match: :first
    end
  end

  test "the Preview tab renders through GitHub's /markdown and Write keeps the text" do
    block = find("[data-testid=md-block][data-commentable=true]", match: :first)
    block_id = open_composer_for(block)

    stub_github_markdown(fixture: "markdown.html")

    within "#composer_#{block_id}" do
      area = find("textarea", match: :first)
      area.click
      area.send_keys("Nice catch, @octocat see #12")

      click_on "Preview"
      assert_selector "[data-markdown-preview-target=previewBody] a.user-mention", text: "octocat", wait: 5
    end

    expect_github_received(:post, "/markdown") do |body|
      body["text"] == "Nice catch, @octocat see #12" && body["mode"] == "gfm" && body["context"] == "#{OWNER}/#{REPO}"
    end

    within "#composer_#{block_id}" do
      click_on "Write"
      assert_field type: "textarea", with: "Nice catch, @octocat see #12"
    end
  end

  private

  def files_json
    [ { "filename" => PATH, "status" => "modified", "additions" => 2, "deletions" => 0, "changes" => 2,
        "patch" => PATCH, "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{PATH}" } ].to_json
  end
end
