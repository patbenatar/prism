# frozen_string_literal: true

require "application_system_test_case"

# Every screen, in both themes, at laptop width — saved to tmp/screenshots so
# a designer can look at the pair side by side.
#
# This is the design check for dark mode; DarkModeTest is the assertion suite.
# It still asserts each screen rendered, so a broken partial fails here too,
# but the point is the PNGs: a contrast table says a colour is legible and
# tells you nothing about whether the page is pleasant to read at 11pm.
#
# Named `theme-<screen>-<light|dark>.png`, so `ls tmp/screenshots/theme-*`
# sorts into pairs.
class ThemeScreenshotsTest < ApplicationSystemTestCase
  include FeatureHelpers

  OWNER = FeatureHelpers::FEATURE_OWNER
  REPO = FeatureHelpers::FEATURE_REPO
  NUMBER = FeatureHelpers::FEATURE_NUMBER
  PATH = "docs/guide.md"
  HEAD_SHA = FeatureHelpers::FEATURE_HEAD_SHA
  BASE_SHA = FeatureHelpers::FEATURE_BASE_SHA

  LAPTOP = [ 1440, 1000 ].freeze
  PHONE = [ 390, 844 ].freeze

  # The base side of docs/guide.md, matching the patch in pull_files.json —
  # same document ThreadPlacementTest reviews, so the review screen here is
  # the real one with a thread of every kind on it.
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
    resize_window(*LAPTOP)
  end

  test "the signed-out screen in both themes" do
    each_theme do |theme|
      visit sign_in_path
      assert_selector "[data-testid=sign-in]"
      shoot("sign-in", theme)
    end
  end

  test "the browsing screens in both themes" do
    stub_browsing
    sign_in_as(@user)

    screens = {
      "repos" => repos_path,
      "pull-list" => repo_pulls_path(owner: OWNER, repo: REPO),
      "pull-overview" => repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)
    }

    each_theme do |theme|
      screens.each do |name, path|
        visit path
        assert_selector "[data-testid=top-bar]"
        shoot(name, theme)
      end
    end
  end

  test "the review screen, its threads, an open composer and the tray in both themes" do
    stub_review_screen
    sign_in_for_feature(@user)

    each_theme do |theme|
      # The Markdown tab renders every renderable file on one page; the
      # per-file route redirects into it. Going straight to the tab keeps the
      # screenshot off a redirect.
      visit repo_pull_markdown_path(owner: OWNER, repo: REPO, number: NUMBER)
      assert_selector "[data-testid=rendered-file]"

      # The tray only exists while a review is pending; the shared fixture
      # carries one, so it is on screen from the first paint.
      assert_selector "[data-testid=pending-tray]"
      shoot("review", theme)

      # Scrolled to the threads, which is where the spectrum does most of its
      # work: a pending draft, a resolved thread and an outdated one, each
      # signalled by a band down its left edge. Scrolled to the pending one
      # by name rather than to the foot of the page — every Markdown file is
      # on this page now, so the bottom of it is the last file, not a thread.
      scroll_to(".thread--pending")
      shoot("review-threads", theme)

      # And with a composer open on a block, which is the screen a reviewer
      # spends the most time looking at.
      page.execute_script("window.scrollTo(0, 0)")
      block = first(".md-block[data-block-id]")
      open_composer_for(block)
      assert_selector ".composer-textarea", match: :first
      shoot("review-composer", theme)
    end
  end

  # Dark mode is a palette change, not a layout change, but the one thing a
  # dark page can hide is an overflow: a light element running off the edge
  # shows as a white sliver, and the same element on the dark canvas is the
  # same colour as the page. So the phone width gets a pair too, and the test
  # asserts the document is no wider than the window on top of saving the PNG.
  test "the narrow layout holds in both themes" do
    stub_browsing
    stub_review_screen
    sign_in_as(@user)
    resize_window(*PHONE)

    each_theme do |theme|
      { "repos" => repos_path,
        "review" => repo_pull_markdown_path(owner: OWNER, repo: REPO, number: NUMBER) }.each do |name, path|
        visit path
        assert_selector "[data-testid=top-bar]"
        shoot("#{name}-390", theme)

        overflow = page.evaluate_script(
          "document.documentElement.scrollWidth - document.documentElement.clientWidth"
        )
        assert_operator overflow, :<=, 0, "#{path} scrolls horizontally at 390px in #{theme} mode"
      end
    end
  ensure
    resize_window(*LAPTOP)
  end

  private

  def each_theme
    yield "light"
    with_color_scheme(:dark) { yield "dark" }
  end

  def shoot(name, theme)
    save_screenshot(Rails.root.join("tmp/screenshots/theme-#{name}-#{theme}.png"))
  end

  # Puts `selector` a third of the way down the viewport, so the shot has some
  # of the document above it for context rather than the element pinned under
  # the two sticky bars.
  def scroll_to(selector)
    assert_selector selector, match: :first
    page.execute_script(<<~JS)
      (() => {
        const el = document.querySelector(#{selector.to_json});
        if (!el) return;
        const top = el.getBoundingClientRect().top + window.scrollY;
        window.scrollTo(0, Math.max(0, top - window.innerHeight / 3));
      })()
    JS
  end

  def stub_browsing
    stub_github_get("/user/repos", fixture: :repos)
    stub_github_get("/repos/#{OWNER}/#{REPO}", fixture: :repo)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls", fixture: :pulls)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/files", fixture: :pull_files)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", fixture: :reviews)
    stub_github_markdown(fixture: "markdown.html")
  end

  def stub_review_screen
    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER)
    stub_feature_mentionables(owner: OWNER, repo: REPO)
    stub_github_markdown(fixture: "markdown.html")
    stub_feature_contents(PATH, HEAD_SHA, github_fixture_raw("guide.md"), owner: OWNER, repo: REPO)
    stub_feature_contents(PATH, BASE_SHA, BASE_GUIDE, owner: OWNER, repo: REPO)
    stub_github_graphql(:ReviewThreads, fixture: :review_threads)
  end
end
