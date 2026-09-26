# frozen_string_literal: true

require "application_system_test_case"

# The optimistic card is the same shape as the comment that replaces it.
#
# `composer_controller#showProvisional` renders the reviewer's words the
# instant they submit, because a GitHub round trip is 200-400ms. Until
# 2026-09-26 that card was a head and a body and nothing else — no tools, no
# reactions row, no reply box — so it stood about 70px tall against the 172px
# the settled thread needs, and the page jumped by the difference the moment
# the response landed. It reserves the whole thread's layout now, with the
# controls that only mean something once the comment exists present but
# disabled.
#
# This measures both states in the same browser and fails on any difference,
# because that is the kind of regression that comes back silently: every
# assertion about text and testids passes either way.
class OptimisticCommentTest < ApplicationSystemTestCase
  include FeatureHelpers

  OWNER = FeatureHelpers::FEATURE_OWNER
  REPO = FeatureHelpers::FEATURE_REPO
  NUMBER = FeatureHelpers::FEATURE_NUMBER
  PATH = "docs/guide.md"
  HEAD_SHA = FeatureHelpers::FEATURE_HEAD_SHA

  DOC = <<~MD
    # Release notes

    Intro paragraph that a reviewer is about to comment on.

    Closing paragraph of the document.
  MD

  PATCH = ([ "@@ -1,1 +1,5 @@", " # Release notes" ] + (1..4).map { "+" }).join("\n")

  BODY = "A brand new comment being saved right now."

  # Long enough that the provisional card is still on screen when the test
  # measures it, and short enough not to slow the suite down. The stub sleeps
  # inside Capybara's own server thread, which is what a real slow GitHub
  # looks like from the browser's side.
  ROUND_TRIP = 3

  setup do
    @user = users(:prism_dev)
    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER, files_body: files_json)
    stub_feature_mentionables(owner: OWNER, repo: REPO)
    stub_github_markdown(fixture: "markdown.html")
    stub_feature_contents(PATH, HEAD_SHA, DOC, owner: OWNER, repo: REPO)
    stub_feature_reviews_sequence([])
    stub_feature_review_threads([])
    sign_in_for_feature(@user)
  end

  test "the card being saved is exactly as tall as the comment that replaces it" do
    stub_slow_add_thread

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    block_id = submit_a_comment

    assert_selector "[data-testid=provisional-comment]", wait: 3
    sending = box("[data-testid=provisional-comment]")

    assert_selector "#threads_#{block_id} [data-testid=thread]", wait: ROUND_TRIP + 10
    assert_no_selector "[data-testid=provisional-comment]"
    settled = box("#threads_#{block_id} [data-testid=thread]")

    assert_equal settled["height"], sending["height"],
                 "the card being saved is #{sending['height']}px and the saved comment is " \
                 "#{settled['height']}px — the page jumps by the difference when the response " \
                 "lands. Every row the settled thread has must be reserved while it is in flight."
    assert_equal settled["left"], sending["left"],
                 "the two states start at different left edges (#{sending['left']} then " \
                 "#{settled['left']})"
    assert_equal settled["width"], sending["width"],
                 "the two states are different widths (#{sending['width']} then #{settled['width']})"
  end

  # Reserving the space is only half of it: a control that cannot work yet
  # must not look usable, must not take focus, and must not be announced.
  test "the controls the saving card reserves are disabled, unfocusable and unannounced" do
    stub_slow_add_thread

    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    submit_a_comment

    assert_selector "[data-testid=provisional-comment]", wait: 3

    reserved = page.evaluate_script(<<~JS)
      (function () {
        var card = document.querySelector("[data-testid=provisional-comment]");
        var rows = ["comment-tools", "comment-actions", "thread-foot"].map(function (name) {
          var row = card.querySelector("." + name);
          return { name: name, present: !!row, inert: !!(row && row.inert),
                   dimmed: row ? parseFloat(getComputedStyle(row).opacity) : null };
        });
        return {
          rows: rows,
          // `inert` takes a subtree out of the tab order, so nothing inside
          // the reserved rows can be reached — this is the check that the
          // keyboard cannot get at a control that does not work yet.
          focusable: card.querySelectorAll(
            "a[href], button:not([disabled]), textarea:not([disabled]), input:not([disabled])"
          ).length,
          replyBoxDisabled: !!card.querySelector(".composer-textarea")?.disabled,
          resolveDisabled: !!card.querySelector(".thread-foot-actions button")?.disabled
        };
      })()
    JS

    reserved["rows"].each do |row|
      assert row["present"], "the saving card does not reserve the room for .#{row['name']}"
      assert row["inert"], ".#{row['name']} is reserved but not inert — it is still in the tab " \
                           "order and still announced as something you can use"
      assert_operator row["dimmed"], :<, 1.0,
                      ".#{row['name']} is reserved at full opacity, so it reads as usable"
    end

    assert reserved["replyBoxDisabled"], "the reserved reply box is not a disabled control"
    assert reserved["resolveDisabled"], "the reserved resolve button is not a disabled control"
    assert_equal 0, reserved["focusable"],
                 "#{reserved['focusable']} enabled controls inside the card being saved — none of " \
                 "them can do anything until GitHub answers"

    # Let the round trip finish before the test ends. Capybara clears the
    # session between tests and cannot do it cleanly while a request the
    # browser started is still open, which shows up as the *next* test failing
    # to sign in.
    assert_selector "[data-testid=thread]", wait: ROUND_TRIP + 10
    assert_no_selector "[data-testid=provisional-comment]"
  end

  private

  # WebMock's dynamic response block runs on the thread serving the browser's
  # request, so sleeping here holds the round trip open exactly the way a slow
  # GitHub would.
  def stub_slow_add_thread
    stub_request(:post, "#{GithubStubs::API}/graphql")
      .with { |request| graphql_operation_name(request.body) == "AddThread" }
      .to_return do
        sleep ROUND_TRIP
        { status: 200,
          body: { data: { addPullRequestReviewThread: { thread: settled_thread } } }.to_json,
          headers: GithubStubs::JSON_HEADERS }
      end
  end

  def submit_a_comment
    block = all("[data-testid=md-block]")[1]
    block_id = open_composer_for(block)

    within "#composer_#{block_id}" do
      find("textarea", match: :first).send_keys(BODY)
      click_on "Add single comment"
    end

    block_id
  end

  def box(selector)
    page.evaluate_script(<<~JS)
      (function () {
        var el = document.querySelector(#{selector.to_json});
        if (!el) return null;
        var r = el.getBoundingClientRect();
        return { height: Math.round(r.height), width: Math.round(r.width), left: Math.round(r.left) };
      })()
    JS
  end

  def settled_thread
    feature_thread(node_id: "PRRT_optimistic", path: PATH, line: 3,
                   comments: [ feature_comment(node_id: "PRRC_optimistic", body: BODY,
                                               author_login: "prism-dev",
                                               viewer_can_update: true, viewer_can_delete: true) ])
  end

  def files_json
    [ { "filename" => PATH, "status" => "modified", "additions" => 4, "deletions" => 0,
        "patch" => PATCH,
        "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{PATH}" } ]
  end
end
