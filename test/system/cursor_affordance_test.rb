# frozen_string_literal: true

require "application_system_test_case"

# Everything you can click shows a pointer.
#
# Tailwind's preflight resets `<button>` to the default arrow, which left the
# gutter "+", a reaction, "Submit review" and a `<summary>` used as a menu all
# reading as text while every plain link read as a control. The fix is one
# rule in `@layer base` (DESIGN.md §5), so this test's job is to catch the
# regression where someone re-specifies `cursor` on a component and undoes it
# — and to catch a *new* kind of control the base rule's selector list does
# not cover.
#
# It walks the real page rather than asserting on the stylesheet, because the
# question is what the browser computed after every rule has fought it out.
class CursorAffordanceTest < ApplicationSystemTestCase
  include FeatureHelpers

  REVIEW_PATH = "docs/guide.md"

  # The base side of docs/guide.md, matching the patch fixture.
  BASE_GUIDE = <<~MARKDOWN
    # Guide

    Existing text.

    Some filler so the line numbers line up with the patch fixture.

    More filler.

    ## Section
    Prose here.
    Old line.
    Tail.
  MARKDOWN

  setup do
    @user = users(:prism_dev)
    stub_github_get("/user/repos", fixture: :repos)
    stub_github_get("/repos/acme/docs-site", fixture: :repo)
    stub_github_get("/repos/acme/docs-site/pulls", fixture: :pulls)
    stub_feature_pull_request
    stub_feature_mentionables
    stub_github_markdown(fixture: "markdown.html")
    stub_feature_contents(REVIEW_PATH, FeatureHelpers::FEATURE_HEAD_SHA, github_fixture_raw("guide.md"))
    stub_feature_contents(REVIEW_PATH, FeatureHelpers::FEATURE_BASE_SHA, BASE_GUIDE)
    stub_github_graphql(:ReviewThreads, fixture: :review_threads)
  end

  # The review screen carries most of the app's buttons — the gutter "+", the
  # composer's tabs and its Write/Preview/Cancel/submit row, a comment's edit
  # and delete icons, reactions, the reaction picker's <summary>, the tray —
  # so it is the screen this rule most needs to hold on, and the one most
  # likely to grow a new kind of control.
  test "every enabled control shows a pointer, on every screen" do
    sign_in_as(@user)

    [ repos_path,
      repo_pulls_path(owner: "acme", repo: "docs-site"),
      repo_pull_path(owner: "acme", repo: "docs-site", number: 42),
      repo_pull_markdown_path(owner: "acme", repo: "docs-site", number: 42) ].each do |path|
      visit path
      assert_selector "[data-testid=top-bar]"

      assert_all_controls_point_at(path)
    end
  end

  # The submit panel lives inside a closed <details> in the tray, so the sweep
  # above never reaches it — which is how its three radio LABELS kept an arrow
  # while the radios beside them showed a pointer. A label wrapping a control
  # is the click target, usually a bigger one than the control, so the two
  # halves of one affordance have to agree.
  test "the controls behind a closed disclosure point too" do
    sign_in_as(@user)
    open_pull_file(path: REVIEW_PATH)

    find("[data-testid=review-submit-open]").click
    assert_selector "[data-testid=review-event-approve]"

    assert_all_controls_point_at("the review submit panel")
  end

  # The other half of the rule: a pointer on something you cannot click is as
  # wrong as an arrow on something you can. A textarea is the one that would
  # actually get caught by a careless `.composer-card * { cursor: pointer }`.
  test "the composer's textarea keeps the text cursor" do
    sign_in_as(@user)
    open_pull_file(path: REVIEW_PATH)

    block = first(".md-block[data-block-id]")
    open_composer_for(block)
    assert_selector "textarea", match: :first

    assert_equal "text", computed_style("textarea", "cursor"),
                 "a text field must not inherit the pointer the base layer gives controls"
  end

  test "the sign-in button and the tabs show a pointer" do
    visit sign_in_path
    assert_equal "pointer", computed_style("[data-testid=sign-in] button, button[data-testid=sign-in]", "cursor")

    sign_in_as(@user)
    visit repo_pulls_path(owner: "acme", repo: "docs-site")
    assert_equal "pointer", computed_style(".tab", "cursor")
  end

  test "a disabled button keeps the not-allowed cursor" do
    sign_in_as(@user)
    visit repos_path

    cursor = page.evaluate_script(<<~JS)
      (() => {
        const el = document.createElement('button');
        el.className = 'btn-primary';
        el.disabled = true;
        el.textContent = 'Submit review';
        document.body.appendChild(el);
        const value = getComputedStyle(el).cursor;
        el.remove();
        return value;
      })()
    JS

    assert_equal "not-allowed", cursor,
                 "`.btn`'s disabled:cursor-not-allowed must still beat the base pointer rule"
  end

  private

  def assert_all_controls_point_at(where)
    arrows = arrow_cursor_controls
    assert_empty arrows,
                 "#{where} has #{arrows.length} clickable element(s) still showing the default " \
                 "cursor:\n#{arrows.join("\n")}"
  end

  # Every element that behaves as a control and is still showing `auto` or
  # `default`. Links are excluded: the browser already gives an `<a href>` a
  # pointer, and an `<a>` without one is not a control.
  def arrow_cursor_controls
    page.evaluate_script(<<~JS)
      (() => {
        const out = [];
        const selector = 'button:not(:disabled), summary, [role="button"], ' +
                         'input[type="submit"]:not(:disabled), input[type="checkbox"]:not(:disabled), ' +
                         'input[type="radio"]:not(:disabled), select:not(:disabled), ' +
                         'label:has(input[type="checkbox"]), label:has(input[type="radio"])';
        for (const el of document.querySelectorAll(selector)) {
          if (el.offsetParent === null && el.tagName !== 'SUMMARY') continue;
          const cursor = getComputedStyle(el).cursor;
          if (cursor === 'auto' || cursor === 'default') {
            out.push(el.tagName.toLowerCase() + '.' + String(el.className || '').slice(0, 60) +
                     ' → ' + cursor);
          }
        }
        return out;
      })()
    JS
  end
end
