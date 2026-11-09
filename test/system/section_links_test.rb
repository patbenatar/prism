# frozen_string_literal: true

require "application_system_test_case"

# Linking to a section of a rendered Markdown file, in a real browser: the
# heading's own link, arriving at one by URL, the links an author writes
# between their own sections, and all of it on a page holding several files.
#
# The documents are built here because every case needs something the shared
# fixtures do not have: two files with the same heading, a heading written
# twice in one file, a heading folded away, and one the pull request deleted.
class SectionLinksTest < ApplicationSystemTestCase
  include FeatureHelpers

  OWNER = FeatureHelpers::FEATURE_OWNER
  REPO = FeatureHelpers::FEATURE_REPO
  NUMBER = FeatureHelpers::FEATURE_NUMBER
  HEAD_SHA = FeatureHelpers::FEATURE_HEAD_SHA
  BASE_SHA = FeatureHelpers::FEATURE_BASE_SHA

  README = "README.md"
  GUIDE = "docs/guide.md"
  HANDBOOK = "docs/handbook.md"
  CHANGELOG = "docs/changelog.md"

  FILLER = (1..12).map { |n| "Filler paragraph #{n}, there so the next heading starts below the fold." }

  # A contents list GitHub authors write by hand, against GitHub's slugs —
  # including `#setup-1`, which only exists because the heading is repeated.
  README_BODY = <<~MD
    # Project

    ## Contents

    - [Overview](#overview)
    - [Setup](#setup)
    - [Setup, the second time](#setup-1)

    ## Overview

    The README's overview.

    #{FILLER.join("\n\n")}

    ## Setup

    The first setup.

    #{FILLER.join("\n\n")}

    ## Setup

    The second setup.

    #{FILLER.join("\n\n")}
  MD

  # The same `## Overview` as the README, so the two files' ids would collide
  # if nothing scoped them.
  GUIDE_BODY = <<~MD
    # Guide

    [Jump to this guide's overview](#overview)

    #{FILLER.join("\n\n")}

    ## Overview

    The guide's overview.

    #{FILLER.join("\n\n")}
  MD

  # Twenty-four paragraphs with an edit near each end, so the middle — and
  # the heading standing in for paragraph 10 — folds away as unchanged.
  def self.handbook(edited:)
    "# Handbook\n\n" + (1..24).map { |n|
      case n
      when 1 then edited ? "The opening paragraph, rewritten." : "The opening paragraph, as it was."
      when 10 then "## Deep section"
      when 20 then edited ? "The twentieth paragraph, rewritten." : "The twentieth paragraph, as it was."
      else "Paragraph #{n}, which nobody touched."
      end
    }.join("\n\n") + "\n"
  end

  HANDBOOK_HEAD = handbook(edited: true)
  HANDBOOK_BASE = handbook(edited: false)

  CHANGELOG_BASE = "# Changelog\n\n## Retired\n\nOld words.\n\n## Current\n\nNew words.\n"
  CHANGELOG_HEAD = "# Changelog\n\n## Current\n\nNew words.\n"

  setup do
    @user = users(:prism_dev)

    stub_feature_pull_request(files_body: files_json, reviews_body: [])
    stub_feature_mentionables
    stub_github_markdown(fixture: "markdown.html")
    stub_feature_contents(README, HEAD_SHA, README_BODY)
    stub_feature_contents(GUIDE, HEAD_SHA, GUIDE_BODY)
    stub_feature_contents(HANDBOOK, HEAD_SHA, HANDBOOK_HEAD)
    stub_feature_contents(HANDBOOK, BASE_SHA, HANDBOOK_BASE)
    stub_feature_contents(CHANGELOG, HEAD_SHA, CHANGELOG_HEAD)
    stub_feature_contents(CHANGELOG, BASE_SHA, CHANGELOG_BASE)
    stub_feature_review_threads([])

    sign_in_for_feature(@user)
  end

  # ------------------------------------------------------ the affordance --

  test "a heading's link appears on hover, after the text, and names the section cleanly" do
    open_page

    heading = section_heading(README, "Overview")
    link = heading.find("[data-testid=heading-link]", visible: :all)

    assert_equal 0.0, opacity(link), "a page at rest is just the document"
    heading.hover
    assert_equal 1.0, opacity(link)

    # A real link, so right-click "copy link" and a middle-click both work,
    # and what they carry is the reader's form rather than an internal id.
    assert_equal "#README.md:overview", link[:href].delete_prefix(markdown_url)
    assert_equal "Link to heading 'Overview'", link["aria-label"]
    assert_not_includes link[:href], "user-content"

    # After the heading's text, and clear of the gutter "+" on the left.
    plus = heading.find(:xpath, "ancestor::*[@data-testid='md-block']").find("[data-testid=gutter-add]", visible: :all)
    assert_operator rect(link)["left"], :>, rect(plus)["right"] + 40
    assert_operator rect(link)["left"], :>=, text_right(heading)

    assert_no_csp_violations
  end

  test "the link is reachable from the keyboard, and shows itself when it has focus" do
    open_page

    link = section_heading(README, "Overview").find("[data-testid=heading-link]", visible: :all)
    page.execute_script("arguments[0].focus({ focusVisible: true })", link.native)

    assert_equal link.native, page.driver.browser.switch_to.active_element
    assert_equal 1.0, opacity(link)
  end

  test "clicking a heading's link puts the section in the URL and keeps the page" do
    open_page
    mark_document

    heading = section_heading(README, "Setup")
    heading.hover
    heading.find("[data-testid=heading-link]").click

    assert_hash "README.md:setup"
    assert_lands_below_the_bars heading
    assert_same_document "a same-page link must not turn into a Turbo visit"
  end

  # --------------------------------------------------------- arriving --

  test "opening a section's URL lands on it, below the pinned bars" do
    visit "#{markdown_path}#README.md:setup"

    assert_lands_below_the_bars section_heading(README, "Setup")
    assert_no_csp_violations
  end

  test "a Turbo visit to a section's URL lands on it too" do
    visit repos_path
    assert_selector "body"
    page.execute_script("window.Turbo.visit(arguments[0])", "#{markdown_path}#docs/guide.md:overview")

    assert_text "The guide's overview."
    assert_lands_below_the_bars section_heading(GUIDE, "Overview")
    assert_no_csp_violations
  end

  test "Back from another page returns to the section's page where the reader left it" do
    visit "#{markdown_path}#README.md:setup"
    heading = section_heading(README, "Setup")
    assert_lands_below_the_bars heading

    # A Turbo visit away, by the tab a reviewer would actually click.
    stub_github_get("/repos/#{OWNER}/#{REPO}/issues/#{NUMBER}/comments", body: [])
    find("[data-testid=pr-tabs] a", text: "Overview").click
    assert_no_selector "[data-testid=rendered-file]"

    page.go_back

    assert_hash "README.md:setup"
    assert_lands_below_the_bars section_heading(README, "Setup")
    assert_no_csp_violations
  end

  test "GitHub's own forms of the fragment still land on the section" do
    visit "#{markdown_path}#setup"
    assert_lands_below_the_bars section_heading(README, "Setup")

    visit "#{markdown_path}#user-content-overview"
    assert_lands_below_the_bars section_heading(README, "Overview")
  end

  # An image above the heading has no height until it loads, and a diagram is
  # drawn after the page arrives. Either pushes the section down after the
  # jump; the landing has to follow it rather than leave the reader a screen
  # short.
  test "the landing holds while the page above the section is still growing" do
    visit "#{markdown_path}#README.md:setup"
    heading = section_heading(README, "Setup")
    assert_lands_below_the_bars heading

    page.execute_script(<<~JS, section_heading(README, "Overview").native)
      const late = document.createElement("div");
      late.style.height = "700px";
      arguments[0].after(late);
    JS

    assert_lands_below_the_bars heading
  end

  test "a link to a section that no longer exists lands on its file" do
    visit "#{markdown_path}#docs/guide.md:renamed-since"

    assert_lands_below(file_section(GUIDE), bars: %w[.topbar .filebar])
  end

  # ------------------------------------------- links inside the document --

  test "the author's table of contents scrolls to the heading and leaves a clean URL" do
    open_page
    mark_document

    within(file_section(README)) { click_link "Setup, the second time" }

    second = file_section(README).all("h2", text: "Setup").last
    assert_hash "README.md:setup-1"
    assert_lands_below_the_bars second
    assert_text "The second setup."
    assert_same_document
  end

  test "back and forward walk the sections the reader visited" do
    open_page
    mark_document

    within(file_section(README)) { click_link "Overview" }
    assert_lands_below_the_bars section_heading(README, "Overview")

    within(file_section(README)) do
      find("h2", text: "Contents").scroll_to(:center)
      click_link "Setup, the second time"
    end
    assert_lands_below_the_bars file_section(README).all("h2", text: "Setup").last

    page.go_back
    assert_hash "README.md:overview"
    assert_lands_below_the_bars section_heading(README, "Overview")

    page.go_forward
    assert_hash "README.md:setup-1"
    assert_lands_below_the_bars file_section(README).all("h2", text: "Setup").last
    assert_same_document "history inside the page is not a Turbo restore"
  end

  test "clicking the same contents link again, after reading on, goes back to it" do
    open_page

    within(file_section(README)) { click_link "Setup" }
    heading = section_heading(README, "Setup")
    assert_lands_below_the_bars heading

    page.execute_script("window.scrollBy(0, 900)")
    within(file_section(README)) do
      find("h2", text: "Contents").scroll_to(:center)
      click_link "Setup"
    end

    assert_lands_below_the_bars heading
  end

  # ------------------------------------------------- several files at once --

  test "two files with the same heading keep separate ids and separate links" do
    open_page

    readme = section_heading(README, "Overview")
    guide = section_heading(GUIDE, "Overview")

    assert_not_equal readme[:id], guide[:id]
    assert_equal 1, all("[id='#{readme[:id]}']", visible: :all).size
    assert_equal "#README.md:overview",
                 readme.find("[data-testid=heading-link]", visible: :all)[:href].delete_prefix(markdown_url)
    assert_equal "#docs/guide.md:overview",
                 guide.find("[data-testid=heading-link]", visible: :all)[:href].delete_prefix(markdown_url)

    ids = page.evaluate_script("Array.from(document.querySelectorAll('[id]'), (e) => e.id)")
    assert_equal ids.uniq, ids, "every id on the page is unique"
  end

  test "an in-document link resolves inside its own file, not the first file that matches" do
    open_page

    within(file_section(GUIDE)) { click_link "Jump to this guide's overview" }

    assert_hash "docs/guide.md:overview"
    assert_lands_below_the_bars section_heading(GUIDE, "Overview")
  end

  test "headings written twice in one file are numbered as GitHub numbers them" do
    open_page

    ids = file_section(README).all("h2", text: "Setup").map { |heading| heading[:id] }
    key = Review::Page.file_key(README)

    assert_equal [ "user-content-#{key}-setup", "user-content-#{key}-setup-1" ], ids
  end

  # ----------------------------------------------------- hidden targets --

  test "a section folded away with the unchanged blocks is opened before the scroll" do
    open_page
    assert_selector "[data-testid=unchanged-run]:not([open])", text: /unchanged blocks/
    assert_no_text "Deep section"

    visit "#{markdown_path}#docs/handbook.md:deep-section"

    assert_selector "[data-testid=unchanged-run][open]"
    assert_lands_below_the_bars section_heading(HANDBOOK, "Deep section")
  end

  test "a section in a collapsed file opens the file first" do
    open_page
    file_section(GUIDE).find("[data-testid=file-toggle]").click
    assert_no_text "The guide's overview."

    page.execute_script("location.hash = arguments[0]", "docs/guide.md:overview")

    assert_text "The guide's overview."
    assert_lands_below_the_bars section_heading(GUIDE, "Overview")
  end

  test "a heading the pull request deleted is revealed from its strip, and offers no link" do
    open_page

    strip_heading = file_section(CHANGELOG).find(".md-removed-body h2", text: "Retired", visible: :all)
    assert_no_selector "#{selector_for(CHANGELOG)} .md-removed-body [data-testid=heading-link]", visible: :all
    assert_not strip_heading.visible?

    visit "#{markdown_path}##{strip_heading[:id]}"

    assert_selector "#{selector_for(CHANGELOG)} [data-testid=removed-strip] details[open]"
    assert_lands_below_the_bars file_section(CHANGELOG).find(".md-removed-body h2", text: "Retired")
  end

  # ---------------------------------------------------------- in both themes --

  # Not an assertion about colour — DarkModeTest owns those — but the pictures
  # a designer needs to judge the link at rest, under the pointer, focused,
  # and the landing it produces. Saved as `section-link-<state>-<theme>.png`.
  test "the heading link, hovered, focused and landed on, in both themes" do
    [ "light", "dark" ].each do |theme|
      with_color_scheme(theme) do
        visit "#{markdown_path}#README.md:overview"
        heading = section_heading(README, "Overview")
        assert_lands_below_the_bars heading

        heading.hover
        assert_equal 1.0, opacity(heading.find("[data-testid=heading-link]"))
        save_screenshot(Rails.root.join("tmp/screenshots/section-link-hover-#{theme}.png"))

        setup = section_heading(README, "Setup")
        setup.scroll_to(:center)
        find("[data-testid=file-bar]").hover
        link = setup.find("[data-testid=heading-link]", visible: :all)
        page.execute_script("arguments[0].focus({ focusVisible: true })", link.native)
        assert_equal 1.0, opacity(link)
        save_screenshot(Rails.root.join("tmp/screenshots/section-link-focus-#{theme}.png"))

        resize_window(390, 844)
        visit "#{markdown_path}#docs/guide.md:overview"
        assert_lands_below_the_bars section_heading(GUIDE, "Overview")
        save_screenshot(Rails.root.join("tmp/screenshots/section-link-phone-#{theme}.png"))
        resize_window(*DEFAULT_WINDOW)
      end
    end

    assert_no_csp_violations
  end

  # -------------------------------------------------------- phone width --

  test "at phone width the link is always visible, beside the heading, and still lands right" do
    resize_window(390, 844)
    open_page

    heading = section_heading(README, "Overview")
    link = heading.find("[data-testid=heading-link]")

    assert_equal 1.0, opacity(link), "there is no hover on a touch screen"
    assert_operator rect(link)["right"], :<=, 390, "no horizontal overflow"
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 390

    link.click
    assert_hash "README.md:overview"
    assert_lands_below_the_bars heading
  end

  private

  def markdown_path = repo_pull_markdown_path(owner: OWNER, repo: REPO, number: NUMBER)

  def markdown_url = "#{Capybara.current_session.server_url}#{markdown_path}"

  def open_page
    visit markdown_path
    assert_selector "[data-testid=rendered-file]", count: 4
  end

  def selector_for(path) = "##{Review::Page.file_key(path)}"

  def section_heading(path, text)
    file_section(path).find("h1, h2, h3, h4, h5, h6", text: text, exact_text: true, match: :first)
  end

  def assert_hash(expected)
    assert_equal expected, URI.decode_www_form_component(page.evaluate_script("location.hash").delete_prefix("#"))
  end

  # The heading clears every pinned bar above it — the top bar, the page's
  # file bar and its own file's sticky heading — and is the first thing under
  # them, not somewhere further down the screen.
  def assert_lands_below_the_bars(heading)
    section = heading.find(:xpath, "ancestor::section[@data-testid='file-section']")
    assert_lands_below(heading, bars: [ ".topbar", ".filebar", "##{section[:id]} > [data-testid=file-head]" ])
  end

  def assert_lands_below(element, bars:)
    # The scroll is a frame late by design, and the page may still be finding
    # its height; give it the moment it needs.
    wait_for_scroll_to_settle

    bottom = bars.map { |bar| page.evaluate_script("document.querySelector(arguments[0]).getBoundingClientRect().bottom", bar) }.max
    top = rect(element)["top"]

    assert_operator top, :>=, bottom - 1, "#{element.text.inspect} is hidden under a pinned bar (top #{top}, bars end #{bottom})"
    assert_operator top, :<=, bottom + 40, "#{element.text.inspect} should be at the top of the reading area (top #{top}, bars end #{bottom})"
  end

  def wait_for_scroll_to_settle
    previous = nil
    10.times do
      current = page.evaluate_script("window.scrollY")
      break if current == previous

      previous = current
      sleep 0.1
    end
  end

  # A marker on the document itself: a Turbo visit, restore or otherwise,
  # renders a new <body> and the marker goes with the old one.
  def mark_document
    page.execute_script("document.body.dataset.sectionLinksMarker = 'kept'")
  end

  def assert_same_document(message = "the page was re-rendered")
    assert_equal "kept", page.evaluate_script("document.body.dataset.sectionLinksMarker"), message
  end

  def opacity(element)
    # Past the 150ms transition, so this reads where it settled.
    sleep 0.25
    page.evaluate_script("parseFloat(getComputedStyle(arguments[0]).opacity)", element.native)
  end

  def rect(element)
    page.evaluate_script("arguments[0].getBoundingClientRect().toJSON()", element.native)
  end

  # Where the heading's own words end, measured on its first text node.
  def text_right(heading)
    page.execute_script(<<~JS, heading.native)
      const range = document.createRange();
      range.selectNodeContents(arguments[0].firstChild);
      return range.getBoundingClientRect().right;
    JS
  end

  def files_json
    # The changelog is not last: a heading near the end of the page cannot be
    # scrolled to the top of the screen, because there is no page left below
    # it to scroll into.
    [ added(README, README_BODY), modified(CHANGELOG, changelog_patch, additions: 0, deletions: 4),
      added(GUIDE, GUIDE_BODY), modified(HANDBOOK, handbook_patch, additions: 2, deletions: 2) ]
  end

  def added(path, body)
    lines = body.lines.map(&:chomp)
    patch = ([ "@@ -0,0 +1,#{lines.size} @@" ] + lines.map { |line| "+#{line}" }).join("\n")

    { "filename" => path, "status" => "added", "additions" => lines.size, "deletions" => 0,
      "changes" => lines.size, "patch" => patch,
      "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{path}" }
  end

  def modified(path, patch, additions:, deletions:)
    { "filename" => path, "status" => "modified", "additions" => additions, "deletions" => deletions,
      "changes" => additions + deletions, "patch" => patch,
      "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{path}" }
  end

  # The folding test's two hunks: one edit at each end, three lines of
  # context, and the deep section untouched between them.
  def handbook_patch
    [
      "@@ -1,5 +1,5 @@",
      " # Handbook",
      " ",
      "-The opening paragraph, as it was.",
      "+The opening paragraph, rewritten.",
      " ",
      " Paragraph 2, which nobody touched.",
      "@@ -39,5 +39,5 @@",
      " Paragraph 19, which nobody touched.",
      " ",
      "-The twentieth paragraph, as it was.",
      "+The twentieth paragraph, rewritten.",
      " ",
      " Paragraph 21, which nobody touched."
    ].join("\n")
  end

  def changelog_patch
    [
      "@@ -1,9 +1,5 @@",
      " # Changelog",
      " ",
      "-## Retired",
      "-",
      "-Old words.",
      "-",
      " ## Current",
      " ",
      " New words."
    ].join("\n")
  end
end
