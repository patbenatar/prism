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

    # Not just that a banner is there: when it lifts is the only thing on it
    # a reviewer can act on, and the test is named for it.
    assert_selector "[data-testid=rate-limit-banner]", text: /try again in \d+ minutes/i
    assert_selector "[data-testid=rendered-file] h1", text: "Guide"
    assert_no_selector "[data-testid=thread]"
  end

  # The 403 page (`shared/forbidden`) is what an organization that has not
  # approved Prism looks like — the most likely first thing a new reviewer at
  # a company sees — and nothing at any tier had ever rendered it. The 404
  # sibling is covered (edge_files_test, pull_requests_test); this one was
  # reachable only in production.
  test "a repository GitHub refuses explains itself and offers a way back" do
    stub_github_get("/user/repos", fixture: :repos)
    stub_github_error(:get, "/repos/#{OWNER}/#{REPO}", status: 403,
                      message: "Resource protected by organization SAML enforcement")
    sign_in_for_feature(@user)

    visit repo_pulls_path(owner: OWNER, repo: REPO)

    assert_selector "[data-testid=empty-state]", text: /GitHub refused this request/i
    assert_text(/may not have access to this repository/i)

    click_on "Back to repositories"
    assert_selector "[data-testid=repo-list]"
  end

  # The failure that had no page at all. Every read screen went through
  # GithubErrorHandling, which rescued 404, 403 and the rate limit and let a
  # 5xx through as a Rails 500 — so a GitHub outage looked to a reviewer
  # exactly like a bug in Prism, with nothing on the screen to say otherwise
  # and nothing to do about it.
  test "GitHub being down is a page that says so, not a 500, and not a missing pull request" do
    stub_github_get("/user/repos", fixture: :repos)
    stub_github_error(:get, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", status: 503,
                      message: "Service unavailable")
    sign_in_for_feature(@user)

    visit repo_pull_markdown_path(owner: OWNER, repo: REPO, number: NUMBER)

    assert_selector "[data-testid=empty-state]", text: /GitHub isn't answering/i
    # Not the 404's wording. "GitHub has nothing here" would tell a reviewer
    # their pull request is gone, which is a different thing to be wrong about.
    assert_no_text(/GitHub has nothing here/i)

    # And the advice is actionable, which is the other half of why this is its
    # own page: retrying a 404 is pointless, retrying this is the fix.
    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER, files_body: files_json, reviews_body: [])
    stub_feature_contents(PATH, HEAD_SHA, HEAD, owner: OWNER, repo: REPO)
    stub_feature_review_threads([])

    click_on "Try again"

    assert_selector "[data-testid=rendered-file] h1", text: "Guide"
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
    # Not "expired": OAuth App tokens don't expire, they get revoked or
    # re-issued. See Github::Unauthorized.
    assert_selector "[data-testid=flash]", text: /GitHub refused your sign-in/i
  end

  private

  def files_json
    [ { "filename" => PATH, "status" => "modified", "additions" => 2, "deletions" => 0, "changes" => 2,
        "patch" => PATCH, "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{PATH}" } ].to_json
  end
end
