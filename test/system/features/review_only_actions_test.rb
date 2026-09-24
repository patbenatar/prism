# frozen_string_literal: true

require "application_system_test_case"

# While a pending review is open, GitHub refuses both standalone writes:
#
#   * `addPullRequestReviewThread` with a `pullRequestId` — the "Add single
#     comment" path — attaches the comment to the open review and answers with
#     it in state PENDING, so the reviewer gets a draft they did not ask for.
#   * REST `/comments/:id/replies` — the immediate "Reply" path — fails 422
#     with "user_id can only have one pending review per pull request",
#     because a standalone reply implicitly opens a second review.
#
# Both were verified against the live API (2026-09-23) after a reviewer hit
# them twice in production. Prism's answer is GitHub's own: while a review is
# open those two controls are absent, with one line where they were, and
# everything goes into the review until it is submitted.
class ReviewOnlyActionsTest < ApplicationSystemTestCase
  include FeatureHelpers

  OWNER = FeatureHelpers::FEATURE_OWNER
  REPO = FeatureHelpers::FEATURE_REPO
  NUMBER = FeatureHelpers::FEATURE_NUMBER
  PATH = "docs/guide.md"
  HEAD_SHA = FeatureHelpers::FEATURE_HEAD_SHA
  REVIEW_ID = 80002
  REVIEW_NODE_ID = "PRR_kwDOABCD12MAAAABc9BB"

  HEAD = <<~MARKDOWN
    # Guide

    This paragraph is brand new.
  MARKDOWN

  PATCH = [ "@@ -1,1 +1,3 @@", " # Guide", "+", "+This paragraph is brand new." ].join("\n")

  setup do
    @user = users(:prism_dev)

    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER, files_body: files_json)
    stub_feature_mentionables(owner: OWNER, repo: REPO)
    stub_feature_references(owner: OWNER, repo: REPO)
    stub_github_markdown(fixture: "markdown.html")
    stub_feature_contents(PATH, HEAD_SHA, HEAD, owner: OWNER, repo: REPO)

    sign_in_for_feature(@user)
  end

  test "with no pending review both standalone actions are offered" do
    stub_feature_reviews_sequence([])
    stub_feature_review_threads([ existing_thread ])

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)

    block_id = open_composer_for(first_block)
    within "#composer_#{block_id}" do
      assert_selector "[data-testid=composer-submit-single]"
      assert_selector "[data-testid=composer-submit-review]", text: "Start a review"
      assert_no_selector "[data-testid=composer-review-only-note]"
    end

    within_open_reply do
      assert_selector "[data-testid=reply-submit]"
      assert_no_selector "[data-testid=reply-review-only-note]"
    end
  end

  test "with a pending review the composer offers only the review action" do
    stub_feature_reviews_sequence([ github_fixture(:pending_review) ])
    stub_feature_review_threads([ existing_thread ])

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    assert_selector "[data-testid=pending-count]"

    block_id = open_composer_for(first_block)
    within "#composer_#{block_id}" do
      assert_no_selector "[data-testid=composer-submit-single]"
      assert_selector "[data-testid=composer-submit-review]", text: "Add review comment"
      assert_selector "[data-testid=composer-review-only-note]", text: /review is in progress/i
    end
  end

  test "with a pending review the reply box offers only the review action" do
    stub_feature_reviews_sequence([ github_fixture(:pending_review) ])
    stub_feature_review_threads([ existing_thread ])

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    assert_selector "[data-testid=pending-count]"

    within_open_reply do
      assert_no_selector "[data-testid=reply-submit]"
      assert_selector "[data-testid=reply-submit-review]", text: "Add to review"
      assert_selector "[data-testid=reply-review-only-note]", text: /review is in progress/i
    end
  end

  # The state changes mid-session, and nothing reloads: the tray's
  # `pending-review:changed` is the only thing that reaches the reply boxes
  # and the composer template already sitting on the page.
  test "starting a review flips the rest of the page without a reload" do
    state = { reviews: [], threads: [ existing_thread ] }
    stub_feature_reviews_dynamic(state, owner: OWNER, repo: REPO, number: NUMBER)
    stub_feature_review_threads_dynamic(state)
    stub_feature_create_pending_review_dynamic(state, owner: OWNER, repo: REPO, number: NUMBER)

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)

    within_open_reply { assert_selector "[data-testid=reply-submit]" }

    stub_feature_add_thread_dynamic(state, draft_thread)

    block_id = open_composer_for(first_block)
    within "#composer_#{block_id}" do
      area = find("textarea", match: :first)
      area.click
      area.send_keys("Into the review")
      click_on "Start a review"
    end

    assert_selector "[data-testid=pending-count]"

    # The reply box was rendered before the review existed and nothing has
    # re-rendered it.
    within_open_reply do
      assert_no_selector "[data-testid=reply-submit]"
      assert_selector "[data-testid=reply-review-only-note]", text: /review is in progress/i
    end

    # And so was the <template> the next composer is cloned from.
    reopened = open_composer_for(first_block)
    within "#composer_#{reopened}" do
      assert_no_selector "[data-testid=composer-submit-single]"
      assert_selector "[data-testid=composer-submit-review]", text: "Add review comment"
      assert_selector "[data-testid=composer-review-only-note]", text: /review is in progress/i
    end
  end

  test "the review action still adds a draft to the open review" do
    stub_feature_reviews_sequence([ github_fixture(:pending_review) ])
    stub_feature_review_threads([ existing_thread ], [ existing_thread, draft_thread ])
    # Both paths go through the same `AddThread` mutation; what tells them
    # apart is whether the input carries `pullRequestReviewId` (into the
    # review) or `pullRequestId` (standalone, which is the one GitHub turns
    # into a draft behind the reviewer's back).
    stub_github_graphql(:AddThread, data: { addPullRequestReviewThread: { thread: draft_thread } })

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    assert_selector "[data-testid=pending-count]"

    block_id = open_composer_for(first_block)
    within "#composer_#{block_id}" do
      area = find("textarea", match: :first)
      area.click
      area.send_keys("Into the review")
      click_on "Add review comment"
    end

    assert_selector "[data-testid=thread]", text: "Into the review", wait: 5
    expect_github_received(:AddThread) do |vars|
      vars["input"]["pullRequestReviewId"] == REVIEW_NODE_ID && !vars["input"].key?("pullRequestId")
    end
  end

  # The half of the rule that cannot live on the client. Hiding the single
  # button keeps an *informed* page from asking for something GitHub will not
  # do; it does nothing for a page that loaded before the review existed —
  # opened in another tab, or simply left open. That page still offers "Add
  # single comment", still sends `pullRequestId`, and GitHub still answers
  # with a draft. The only honest thing left is to say so, which is the one
  # moment anyone finds out.
  test "a page that predates the review says so when GitHub folds the comment into it" do
    state = { reviews: [], threads: [] }
    stub_feature_reviews_dynamic(state, owner: OWNER, repo: REPO, number: NUMBER)
    stub_feature_review_threads_dynamic(state)

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    assert_no_selector "[data-testid=pending-count]"

    # Between this page rendering and the click below, a review is opened
    # somewhere else — so the comment GitHub is about to receive as a
    # standalone one comes back PENDING.
    stub_joined_add_thread(state)

    block_id = open_composer_for(first_block)
    within "#composer_#{block_id}" do
      assert_selector "[data-testid=composer-submit-single]"
      area = find("textarea", match: :first)
      area.click
      area.send_keys("Meant to post this on its own")
      click_on "Add single comment"
    end

    assert_selector "[data-testid=flash]", text: /review was already in progress, so this joined it/i, wait: 5
    # And the tray it did not have a moment ago, counting the draft it did
    # not mean to write — resynced from GitHub rather than from the form,
    # whose hidden fields still said "no review, nothing pending".
    assert_selector "[data-testid=pending-count]", text: "1 pending comment"
    assert_selector "[data-testid=thread] .pill-pending", text: "Pending"

    expect_github_received(:AddThread) do |vars|
      vars["input"].key?("pullRequestId") && !vars["input"].key?("pullRequestReviewId")
    end
  end

  # The design check for the pair: what the composer and the reply box look
  # like with and without a review in progress, in both schemes, at laptop
  # width. Saved to tmp/screenshots as `review-only-<state>-<theme>.png` —
  # a line standing in for a button has to read as an explanation, not as
  # something missing.
  test "both states at 1440, light and dark" do
    state = { reviews: [], threads: [ existing_thread ] }
    stub_feature_reviews_dynamic(state, owner: OWNER, repo: REPO, number: NUMBER)
    stub_feature_review_threads_dynamic(state)
    resize_window(1440, 1000)

    each_theme do |theme|
      state[:reviews] = []
      state[:threads] = [ existing_thread ]
      shoot_editors("no-review", theme)

      state[:reviews] = [ github_fixture(:pending_review) ]
      state[:threads] = [ existing_thread, draft_thread ]
      shoot_editors("pending-review", theme)
    end
  end

  private

  def each_theme
    yield "light"
    with_color_scheme(:dark) { yield "dark" }
  end

  # Two shots per state, because the two editors do not fit one 1000px frame
  # once the reply box is unfolded: the composer open under the block, and the
  # thread's reply box (which rests collapsed until focus lands in it).
  def shoot_editors(state_name, theme)
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    # `visit` to the URL we are already on, anchor and all, is a same-document
    # navigation: the browser does not re-request the page, so the shot after
    # `state` changed would be of the state before it. Refresh unconditionally.
    page.refresh
    assert_selector "[data-testid=rendered-file]"

    block_id = open_first_composer
    centre("#composer_#{block_id}")
    shoot("composer", state_name, theme)

    reply = find("#thread_PRRT_existing [data-testid=reply-textarea]")
    reply.click
    centre("#thread_PRRT_existing [data-testid=reply-form]")
    shoot("reply", state_name, theme)
  end

  def centre(selector)
    page.execute_script("document.querySelector(arguments[0])?.scrollIntoView({ block: 'center' })", selector)
  end

  def shoot(editor, state_name, theme)
    save_screenshot(Rails.root.join("tmp/screenshots/review-only-#{editor}-#{state_name}-#{theme}.png"))
  end

  # The same retry AutocompleteScreenshotsTest needs: this test loads the page
  # four times, and a Turbo navigation can leave the outgoing page's blocks on
  # screen long enough for the "+" to be clicked on one that is about to be
  # replaced, which opens nothing.
  def open_first_composer
    3.times do
      block = first_block
      block_id = block["data-block-id"]
      block.hover
      block.find(".md-add", match: :first).click

      return block_id if has_selector?("#composer_#{block_id} textarea", wait: 3)
    end

    flunk "the composer never opened"
  end

  def first_block
    find("[data-testid=md-block][data-commentable=true]", match: :first)
  end

  # The reply box rests collapsed — `.composer-card--compact:not(:focus-within)`
  # hides its whole foot — so its buttons are invisible to Capybara until
  # focus lands inside. Asserting on them without this would pass whatever
  # they say.
  # Scoped by node id, not by `[data-testid=thread]`: once a review has been
  # started there are two threads on the page, and this is always asking
  # about the one that was rendered before it.
  def within_open_reply(node_id = "PRRT_existing")
    within "#thread_#{node_id}" do
      find("[data-testid=reply-textarea]").click
      yield
    end
  end

  # GitHub's answer to a standalone comment made while a review is open: the
  # thread comes back with its comment PENDING, and the review it was folded
  # into is now the viewer's — so `state` gains both at the moment the
  # request arrives (never eagerly; see stub_feature_add_thread_dynamic).
  def stub_joined_add_thread(state)
    stub_request(:post, "#{GithubStubs::API}/graphql")
      .with { |request| graphql_operation_name(request.body) == "AddThread" }
      .to_return do
        state[:reviews] = [ github_fixture(:pending_review) ]
        state[:threads] << joined_thread
        { status: 200,
          body: { data: { addPullRequestReviewThread: { thread: joined_thread } } }.to_json,
          headers: GithubStubs::JSON_HEADERS }
      end
  end

  def joined_thread
    @joined_thread ||= feature_thread(
      node_id: "PRRT_joined", path: PATH, line: 3,
      comments: [ feature_comment(node_id: "PRRC_joined", body: "Meant to post this on its own",
                                   state: "PENDING", author_login: "prism-dev") ]
    )
  end

  def existing_thread
    feature_thread(
      node_id: "PRRT_existing", path: PATH, line: 3,
      comments: [ feature_comment(node_id: "PRRC_existing", database_id: 900_100, body: "Worth a second look?") ]
    )
  end

  def draft_thread
    feature_thread(
      node_id: "PRRT_draft", path: PATH, line: 3,
      comments: [ feature_comment(node_id: "PRRC_draft", body: "Into the review", state: "PENDING",
                                   author_login: "prism-dev") ]
    )
  end

  def files_json
    [ { "filename" => PATH, "status" => "modified", "additions" => 2, "deletions" => 0, "changes" => 2,
        "patch" => PATCH, "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{PATH}" } ].to_json
  end
end
