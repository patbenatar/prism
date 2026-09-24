# frozen_string_literal: true

require "application_system_test_case"

# Folding, in a real browser: a whole file down to its heading, and the
# stretches of a modified file the pull request did not touch.
#
# The document is built here rather than taken from the shared fixtures
# because folding only has anything to do on a file long enough to bury a
# change in — twenty-five blocks with an edit near each end.
class FileFoldingTest < ApplicationSystemTestCase
  include FeatureHelpers

  OWNER = FeatureHelpers::FEATURE_OWNER
  REPO = FeatureHelpers::FEATURE_REPO
  NUMBER = FeatureHelpers::FEATURE_NUMBER
  PATH = "docs/handbook.md"
  HEAD_SHA = FeatureHelpers::FEATURE_HEAD_SHA
  BASE_SHA = FeatureHelpers::FEATURE_BASE_SHA
  PR_NODE_ID = FeatureHelpers::FEATURE_PR_NODE_ID

  PARAGRAPHS = 24

  CHANGED = "[data-testid=md-block][data-change]:not([data-change=unchanged])"

  # Paragraph 1 and paragraph 20 are rewritten; everything between them is
  # untouched, which is the stretch that folds.
  HEAD = "# Handbook\n\n" + (1..PARAGRAPHS).map { |n|
    case n
    when 1  then "The opening paragraph, rewritten in this pull request."
    when 20 then "The twentieth paragraph, also rewritten."
    else "Paragraph #{n}, which nobody touched."
    end
  }.join("\n\n") + "\n"

  BASE = "# Handbook\n\n" + (1..PARAGRAPHS).map { |n|
    case n
    when 1  then "The opening paragraph, as it was."
    when 20 then "The twentieth paragraph, as it was."
    else "Paragraph #{n}, which nobody touched."
    end
  }.join("\n\n") + "\n"

  setup do
    @user = users(:prism_dev)
    resize(1440, 900)

    # No pending review: "Add single comment" is hidden while one is open,
    # because GitHub silently folds such a comment into the review anyway.
    stub_feature_pull_request(files_body: files_json, reviews_body: [])
    stub_feature_mentionables
    stub_github_markdown(fixture: "markdown.html")
    stub_feature_contents(PATH, HEAD_SHA, HEAD)
    stub_feature_contents(PATH, BASE_SHA, BASE)
    stub_feature_review_threads([])

    sign_in_for_feature(@user)
  end

  # ------------------------------------------------- folding a whole file --

  test "the file heading folds the file away and survives the fold" do
    open_page

    section = find("##{key}")
    assert_selector "##{key} [data-testid=md-block]", minimum: 5

    section.find("[data-testid=file-toggle]").click

    # The document is gone; the heading, with everything that makes the page
    # an index of the pull request, is not.
    assert_no_selector "##{key} [data-testid=md-block]"
    assert_selector "##{key} [data-testid=file-head]", text: "handbook.md"
    assert_selector "##{key} [data-testid=file-head]", text: "Modified"
    assert_selector "##{key} [data-testid=file-head]", text: /\+2/
    assert_equal "false", section.find("[data-testid=file-toggle]")["aria-expanded"]

    section.find("[data-testid=file-toggle]").click
    assert_selector "##{key} [data-testid=md-block]", minimum: 5
  end

  test "n opens a collapsed file rather than scrolling to nothing" do
    open_page
    find("##{key} [data-testid=file-toggle]").click
    assert_no_selector "##{key} [data-testid=md-block]"

    find("body").send_keys("n")

    # A change inside a folded file is still a change: the jump opens the file
    # on the way in rather than scrolling to something with no box.
    assert_selector "##{key} [data-testid=md-block]", minimum: 5
    assert_equal "true", find("##{key} [data-testid=file-toggle]")["aria-expanded"]
  end

  # ---------------------------------------- folding what didn't change ----

  test "the untouched middle folds, opens, and the blocks inside it work" do
    open_page

    run = find("[data-testid=unchanged-run]")
    assert_match(/\d+ unchanged blocks/, run.text)
    assert_text "The opening paragraph, rewritten"
    assert_no_text "Paragraph 10, which nobody touched"

    run.find("summary").click

    assert_text "Paragraph 10, which nobody touched"
    assert_selector "[data-testid=unchanged-run]", text: "Hide"

    # And a block inside it is a real block the moment it is on screen: the
    # gutter "+" opens a composer and the comment posts against that block.
    block = run.all("[data-testid=md-block]").first
    thread = feature_thread(
      node_id: "PRRT_revealed", path: PATH, line: block["data-start-line"].to_i,
      comments: [ feature_comment(node_id: "PRRC_revealed", body: "Still commentable.") ]
    )
    stub_github_graphql(:AddThread, data: { addPullRequestReviewThread: { thread: thread } })
    stub_feature_review_threads([ thread ])

    comment_on_block(block, body: "Still commentable.")

    assert_selector "[data-testid=thread]", text: "Still commentable.", wait: 5
    expect_github_received(:AddThread) { |vars| vars["input"]["path"] == PATH }
  end

  test "an anchor into a folded run opens it" do
    open_page

    # The block is in the DOM the whole time — that is the point of folding
    # with <details> rather than withholding the markup — so its id can be
    # read while it is still hidden, which is exactly what a `#block_…`
    # permalink from GitHub would carry.
    hidden = find("[data-testid=unchanged-run] [data-testid=md-block]", visible: :all, match: :first)
    id = hidden["id"]
    assert_not hidden.visible?, "it starts folded away"

    visit "#{repo_pull_markdown_path(owner: OWNER, repo: REPO, number: NUMBER)}##{id}"

    assert_selector "##{id}", visible: true
    assert_selector "[data-testid=unchanged-run][open]"
  end

  test "a run holding a comment never folds" do
    # Line 41 is paragraph 15 — deep in the middle that would otherwise fold.
    thread = feature_thread(
      node_id: "PRRT_held", path: PATH, line: HEAD.lines.index { |l| l.start_with?("Paragraph 15,") } + 1,
      comments: [ feature_comment(node_id: "PRRC_held", body: "Held open.") ]
    )
    stub_feature_review_threads([ thread ])

    open_page

    assert_text "Paragraph 15, which nobody touched"
    assert_selector "[data-testid=thread]", text: "Held open."
    assert_equal 0, find("[data-testid=thread]").all(:xpath, "ancestor::details").size,
                 "a hidden comment is a lost comment"
  end

  # ------------------------------------------------------- n and p, in place --

  test "n goes to the next change below where you are, not back to the top" do
    open_page

    # Land on the first change, then scroll past it by hand.
    find("body").send_keys("n")
    assert_selector "[data-testid=changed-count]", text: /1 of 2 changed blocks/

    first_change = find(CHANGED, match: :first)
    scroll_below(first_change)
    sleep 0.9 # past the settling window, so this measures the viewport

    find("body").send_keys("n")

    assert_selector "[data-testid=changed-count]", text: /2 of 2 changed blocks/
    assert_text "The twentieth paragraph, also rewritten"
  end

  test "p goes to the previous change above where you are" do
    open_page

    # Walk down to the second change, then let the page settle so the next
    # key measures the viewport rather than the jump still in flight.
    find("body").send_keys("n")
    find("body").send_keys("n")
    assert_selector "[data-testid=changed-count]", text: /2 of 2 changed blocks/
    sleep 0.9

    find("body").send_keys("p")

    assert_selector "[data-testid=changed-count]", text: /1 of 2 changed blocks/
    assert_text "The opening paragraph, rewritten"
  end

  test "n off the end wraps round to the first change" do
    open_page

    find("body").send_keys("n")
    find("body").send_keys("n")
    assert_selector "[data-testid=changed-count]", text: /2 of 2 changed blocks/

    find("body").send_keys("n")
    assert_selector "[data-testid=changed-count]", text: /1 of 2 changed blocks/
  end

  private

  def key = Review::Page.file_key(PATH)

  def open_page
    visit repo_pull_markdown_path(owner: OWNER, repo: REPO, number: NUMBER)
    assert_selector "[data-testid=rendered-file]"
  end

  # Puts the element's bottom just above the pinned bars, so it is behind the
  # reviewer and the next change is genuinely "below where I am".
  def scroll_below(element)
    page.execute_script(<<~JS, element.native)
      const rect = arguments[0].getBoundingClientRect();
      window.scrollBy({ top: rect.bottom - 120, behavior: "instant" });
    JS
    sleep 0.2
  end

  def resize(width, height)
    page.driver.browser.manage.window.resize_to(width, height)
  end

  def files_json
    [ { "filename" => PATH, "status" => "modified", "additions" => 2, "deletions" => 2,
        "changes" => 4, "patch" => patch,
        "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{PATH}" } ]
  end

  # Two hunks, one at each end of the document, with the three lines of
  # context GitHub gives — so the blocks between them are genuinely outside
  # the diff as well as unchanged.
  def patch
    [
      "@@ -1,5 +1,5 @@",
      " # Handbook",
      " ",
      "-The opening paragraph, as it was.",
      "+The opening paragraph, rewritten in this pull request.",
      " ",
      " Paragraph 2, which nobody touched.",
      "@@ -39,5 +39,5 @@",
      " Paragraph 19, which nobody touched.",
      " ",
      "-The twentieth paragraph, as it was.",
      "+The twentieth paragraph, also rewritten.",
      " ",
      " Paragraph 21, which nobody touched."
    ].join("\n")
  end
end
