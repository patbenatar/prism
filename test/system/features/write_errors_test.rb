# frozen_string_literal: true

require "application_system_test_case"

# Journey 10: GitHub refusing a *write*, in a real browser.
#
# `errors_test.rb` covers the failures a reviewer meets on the way in — a 422
# on the anchor, a rate limit on page load, a dead token on the next
# navigation. This covers the other half: the pull request, the repository or
# the token going wrong *while the reviewer is writing*, which is where the
# damage is. Three things have to hold for each of them, and only a browser
# can check any of them:
#
#   1. Nothing is written. A refusal that still POSTs is worse than a refusal.
#   2. The page says so where the reviewer was looking, and stays usable —
#      ReviewCommentsController deliberately `update`s the composer slot and
#      `replace`s a thread, because replacing the slot would discard the id
#      the composer controller looks it up by for the rest of the page's life
#      (see its own comment on render_repo_error_stream). An integration test
#      can read that stream; it cannot tell you the composer still opens
#      afterwards.
#   3. A turbo_stream response carrying a 403/404/503 status is applied at
#      all. Turbo decides that on the content type alone, but "the framework
#      currently happens to do that" is exactly the kind of assumption worth
#      pinning in a test rather than in a comment.
#
# And one more, which is really the point of all three: the reviewer's own
# words survive. A refusal that costs someone the paragraph they just wrote is
# the worst outcome on this path, and it is the only one they cannot undo.
class WriteErrorsTest < ApplicationSystemTestCase
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

  PULL_PATH = "/repos/#{FeatureHelpers::FEATURE_OWNER}/#{FeatureHelpers::FEATURE_REPO}/pulls/#{FeatureHelpers::FEATURE_NUMBER}"

  setup do
    @user = users(:prism_dev)

    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER, files_body: files_json, reviews_body: [])
    stub_feature_mentionables(owner: OWNER, repo: REPO)
    stub_github_markdown(fixture: "markdown.html")
    stub_feature_contents(PATH, HEAD_SHA, HEAD, owner: OWNER, repo: REPO)

    sign_in_for_feature(@user)
  end

  # The pull request disappearing under a reviewer is a 404 from the very
  # first call `create` makes, so the comment never reaches GitHub at all.
  test "a pull request GitHub can no longer find says so in the composer, writes nothing, and keeps the words" do
    stub_feature_review_threads([])
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)

    block = find("[data-testid=md-block][data-commentable=true]", match: :first)
    block_id = open_composer_for(block)

    stub_github_error(:get, PULL_PATH, status: 404, message: "Not Found")

    within "#composer_#{block_id}" do
      area = find("textarea", match: :first)
      area.click
      area.send_keys("This one is going nowhere.")
      click_on "Add single comment"
    end

    assert_selector "[data-testid=composer-error]",
                    text: /Not found on GitHub, or you don't have access to it/i, wait: 5
    assert_no_selector "[data-testid=provisional-comment]"
    assert_no_selector "[data-testid=thread]"
    assert_empty github_graphql_requests.select { |request| request[:operation] == "AddThread" },
                 "nothing may be written to GitHub when the pull request 404s"

    # The paragraph is still there. This is the whole point: the reviewer did
    # nothing wrong, and retyping it is the one cost of this failure they
    # cannot get back.
    assert_field type: "textarea", with: "This one is going nowhere."

    # And the composer is a working composer, not a message where one used to
    # be — GitHub recovers and the same open composer posts, with no "+" to
    # click again and nothing to retype.
    stub_github_get(PULL_PATH, fixture: :pull)
    thread = feature_thread(node_id: "PRRT_retry", path: PATH, line: 3,
                            comments: [ feature_comment(node_id: "PRRC_retry", body: "This one is going nowhere.") ])
    stub_github_graphql(:AddThread, data: { addPullRequestReviewThread: { thread: thread } })
    stub_feature_review_threads([ thread ])

    within("#composer_#{block_id}") { click_on "Add single comment" }

    assert_selector "[data-testid=thread]", text: "This one is going nowhere.", wait: 5
    expect_github_received(:AddThread) do |vars|
      vars["input"]["path"] == PATH && vars["input"]["body"] == "This one is going nowhere."
    end
  end

  # GitHub having a bad five seconds is not the pull request being gone, and
  # it is the one failure where "try again" is honest advice. Before this it
  # was an unrescued Github::Unavailable — a Rails 500, which Turbo paints
  # straight over the review screen, taking the unsent comment with it.
  test "GitHub falling over mid-comment keeps the review screen, the words, and says to try again" do
    stub_feature_review_threads([])
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)

    block = find("[data-testid=md-block][data-commentable=true]", match: :first)
    block_id = open_composer_for(block)

    stub_github_error(:get, PULL_PATH, status: 503, message: "Service unavailable")

    within "#composer_#{block_id}" do
      area = find("textarea", match: :first)
      area.click
      area.send_keys("Worth keeping through an outage.")
      click_on "Add single comment"
    end

    assert_selector "[data-testid=composer-error]", text: /unavailable|try again/i, wait: 5
    assert_field type: "textarea", with: "Worth keeping through an outage."

    # Still the review screen, not an error page: the document is where it
    # was and the reviewer has lost nothing but a few seconds.
    assert_selector "[data-testid=rendered-file] h1", text: "Guide"
    assert_current_path repo_pull_markdown_path(owner: OWNER, repo: REPO, number: NUMBER)
    assert_empty github_graphql_requests.select { |request| request[:operation] == "AddThread" },
                 "nothing may be written to GitHub when GitHub is the thing that failed"

    stub_github_get(PULL_PATH, fixture: :pull)
    thread = feature_thread(node_id: "PRRT_recovered", path: PATH, line: 3,
                            comments: [ feature_comment(node_id: "PRRC_recovered",
                                                         body: "Worth keeping through an outage.") ])
    stub_github_graphql(:AddThread, data: { addPullRequestReviewThread: { thread: thread } })
    stub_feature_review_threads([ thread ])

    within("#composer_#{block_id}") { click_on "Add single comment" }

    assert_selector "[data-testid=thread]", text: "Worth keeping through an outage.", wait: 5
  end

  # A token revoked while a review is open. The refusal arrives on a Turbo
  # form submission rather than on a navigation, so the redirect
  # Authentication#handle_revoked_token issues (:see_other, because the
  # request was a POST) has to be one Turbo will actually follow.
  test "a token revoked mid-comment signs the reviewer out instead of failing quietly" do
    stub_feature_review_threads([])
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)

    block = find("[data-testid=md-block][data-commentable=true]", match: :first)
    block_id = open_composer_for(block)

    stub_github_error(:get, PULL_PATH, status: 401, message: "Bad credentials")

    within "#composer_#{block_id}" do
      area = find("textarea", match: :first)
      area.click
      area.send_keys("Written against a dead token.")
      click_on "Add single comment"
    end

    assert_current_path sign_in_path, wait: 5
    assert_selector "[data-testid=flash]", text: /GitHub refused your sign-in/i
    assert_predicate @user.reload.access_token, :blank?
  end

  # Resolve is the other shape of write: no composer to fall back into, so the
  # thread itself carries the explanation and everything else on the page is
  # left alone.
  test "a thread the token may not resolve explains itself in place, leaving the rest of the page alone" do
    comment = feature_comment(node_id: "PRRC_forbidden", database_id: 900_700, body: "Can this go?")
    thread = feature_thread(node_id: "PRRT_forbidden", path: PATH, line: 3, comments: [ comment ])
    stub_feature_review_threads([ thread ])

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    assert_selector "[data-testid=thread-resolve]"

    stub_github_error(:post, "/graphql", status: 403, message: "Resource not accessible by integration")

    click_on "Resolve"

    # The explanation takes the thread's place rather than the page's: the
    # stream `replace`s `thread_<node_id>`, so that id is gone afterwards and
    # the card standing where the thread was is the error itself.
    assert_selector "[data-testid=inline-error]", text: /GitHub refused that request/i, wait: 5
    assert_no_selector "#thread_PRRT_forbidden"
    assert_current_path repo_pull_markdown_path(owner: OWNER, repo: REPO, number: NUMBER)
    assert_selector "[data-testid=rendered-file] h1", text: "Guide"
  end

  # Resolve again, with GitHub itself down rather than refusing: the thread
  # carries the explanation, the rest of the page is untouched, and the answer
  # says to try again rather than reading like the thread is gone.
  test "a thread Prism cannot reach because GitHub is down says so without taking the page with it" do
    comment = feature_comment(node_id: "PRRC_down", database_id: 900_900, body: "Still here?")
    thread = feature_thread(node_id: "PRRT_down", path: PATH, line: 3, comments: [ comment ])
    stub_feature_review_threads([ thread ])

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    assert_selector "[data-testid=thread-resolve]"

    stub_github_error(:post, "/graphql", status: 503, message: "Service unavailable")

    click_on "Resolve"

    assert_selector "[data-testid=inline-error]", text: /unavailable|try again/i, wait: 5
    assert_selector "[data-testid=rendered-file] h1", text: "Guide"
  end

  # A rate limit has no in-place answer — the next thing the reviewer does
  # would hit it too — so this one does navigate, and the reason has to
  # survive the redirect rather than dropping the reviewer somewhere with no
  # explanation.
  test "a rate limit while resolving sends the reviewer back with GitHub's own reason" do
    comment = feature_comment(node_id: "PRRC_limited", database_id: 900_800, body: "Ready to resolve.")
    thread = feature_thread(node_id: "PRRT_limited", path: PATH, line: 3, comments: [ comment ])
    stub_feature_review_threads([ thread ])

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    assert_selector "[data-testid=thread-resolve]"

    stub_github_error(:post, "/graphql", status: 403, message: "API rate limit exceeded",
                      headers: { "X-RateLimit-Reset" => 12.minutes.from_now.to_i.to_s })

    click_on "Resolve"

    assert_current_path repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER), wait: 5
    assert_selector "[data-testid=flash]", text: /rate limiting us.*try again in \d+ minutes/i
  end

  private

  def files_json
    [ { "filename" => PATH, "status" => "modified", "additions" => 2, "deletions" => 0, "changes" => 2,
        "patch" => PATCH, "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{PATH}" } ].to_json
  end
end
