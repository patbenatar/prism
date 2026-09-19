# frozen_string_literal: true

require "application_system_test_case"

# Journey 9: GitHub's own failures, surfaced rather than swallowed —
# a 422 on comment create keeps the composer open with the reviewer's text
# and GitHub's message; a 403 rate limit on page load shows a banner with the
# reset time; a 401 on any call signs the reviewer out with a flash.
class ErrorsTest < ApplicationSystemTestCase
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
  end

  test "a 422 'must be part of the diff' error keeps the composer open with the text and GitHub's message" do
    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER, files_body: files_json, reviews_body: [])
    stub_feature_mentionables(owner: OWNER, repo: REPO)
    stub_feature_contents(PATH, HEAD_SHA, HEAD, owner: OWNER, repo: REPO)
    stub_feature_review_threads([])
    sign_in_for_feature(@user)

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)

    block = find("[data-testid=md-block][data-commentable=true]", match: :first)
    block_id = open_composer_for(block)

    stub_github_graphql(:AddThread, errors: [
      { "message" => "Pull request review thread line must be part of the diff" }
    ])

    within "#composer_#{block_id}" do
      area = find("textarea", match: :first)
      area.click
      area.send_keys("My careful comment, kept if this fails.")
      click_on "Add single comment"
    end

    # The error re-render lands back in the same slot, but asserting through
    # the block's own id proved timing-sensitive against the in-flight
    # request (the slot briefly carries the old, disabled form) — matching
    # by testid alone is exactly as specific, since only one composer is ever
    # open at a time, and isn't sensitive to that transient state.
    assert_selector "[data-testid=composer-error]",
                    text: /GitHub only accepts comments on lines that appear in this pull request/i, wait: 5
    assert_field type: "textarea", with: "My careful comment, kept if this fails."
  end

  test "a 403 rate limit on page load shows a banner with when it resets" do
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/files", body: files_json)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", body: [].to_json)
    stub_feature_contents(PATH, HEAD_SHA, HEAD, owner: OWNER, repo: REPO)
    reset_at = 12.minutes.from_now
    stub_github_error(:post, "/graphql", status: 403, message: "API rate limit exceeded",
                      headers: { "X-RateLimit-Reset" => reset_at.to_i.to_s })
    sign_in_for_feature(@user)

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)

    assert_selector "[data-testid=rate-limit-banner]"
    assert_selector "[data-testid=rendered-file] h1", text: "Guide"
    assert_no_selector "[data-testid=thread]"
  end

  test "a 401 on any GitHub call signs the reviewer out with a flash" do
    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER, files_body: files_json, reviews_body: [])
    stub_feature_contents(PATH, HEAD_SHA, HEAD, owner: OWNER, repo: REPO)
    stub_feature_review_threads([])
    sign_in_for_feature(@user)
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)

    # The token dies between requests — the next call (switching to the PR
    # overview) hits it.
    stub_github_error(:get, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", status: 401, message: "Bad credentials")

    visit repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)

    assert_current_path sign_in_path
    assert_selector "[data-testid=flash]", text: /sign-in expired/i
  end

  private

  def files_json
    [ { "filename" => PATH, "status" => "modified", "additions" => 2, "deletions" => 0, "changes" => 2,
        "patch" => PATCH, "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{PATH}" } ].to_json
  end
end
