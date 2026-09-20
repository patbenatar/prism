# frozen_string_literal: true

require "application_system_test_case"

# Journey 1: sign in with GitHub, browse to a pull request, and read one of
# its rendered Markdown files — then sign out, and prove a signed-out deep
# link sends you to sign in and brings you back once you're in.
#
# GitHub is stubbed at the HTTP layer throughout (WebMock); nothing here ever
# reaches the real API.
class SignInAndBrowseTest < ApplicationSystemTestCase
  include FeatureHelpers

  OWNER = FeatureHelpers::FEATURE_OWNER
  REPO = FeatureHelpers::FEATURE_REPO
  NUMBER = FeatureHelpers::FEATURE_NUMBER
  PATH = "docs/guide.md"
  HEAD_SHA = FeatureHelpers::FEATURE_HEAD_SHA
  BASE_SHA = FeatureHelpers::FEATURE_BASE_SHA

  # Consistent with test/fixtures/github/pull_files.json's two-hunk patch for
  # docs/guide.md, and with test/integration/pull_request_files_test.rb's base
  # side — reused here so the same document is proven to render both through a
  # request spec and through a real browser.
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
    stub_github_get("/repos/#{OWNER}/#{REPO}", fixture: :repo)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls", fixture: :pulls,
                    query: hash_including({ "state" => "open" }))
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls", body: [].to_json,
                    query: hash_including({ "state" => "closed" }))
    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER)
    stub_github_markdown(fixture: "markdown.html")
    stub_github_graphql(:ReviewThreads, fixture: :review_threads)
    stub_feature_contents(PATH, HEAD_SHA, github_fixture_raw("guide.md"))
    stub_feature_contents(PATH, BASE_SHA, BASE_GUIDE)
  end

  test "signing in, browsing to a pull request, and reading a rendered Markdown file" do
    mock_github_auth(@user)

    visit root_path
    assert_text "Review a pull request's Markdown"
    click_on "Continue with GitHub"

    # ── Repositories ──────────────────────────────────────────────────────
    assert_selector "[data-testid=repo-list]"
    assert_text REPO
    click_on REPO, match: :first

    # ── Pull requests, open/closed tabs ──────────────────────────────────
    assert_selector "[data-testid=pull-request-list]"
    assert_text "Rewrite the getting-started guide"

    assert_selector "[data-testid=pr-tab-open].tab-active"
    click_on "Closed"
    assert_selector "[data-testid=pr-tab-closed].tab-active"
    assert_no_text "Rewrite the getting-started guide"

    click_on "Open"
    assert_selector "[data-testid=pr-tab-open].tab-active"

    # ── PR overview: the Markdown files lead, everything else follows ────
    click_on "Rewrite the getting-started guide"
    assert_selector "[data-testid=pr-state]", text: "Open"
    assert_selector "[data-testid=markdown-files]"
    assert_selector "[data-testid=markdown-file]", count: 4 # guide/troubleshooting/legacy/install .md
    assert_selector "[data-testid=other-files]"

    # ── Open a Markdown file: rendered, not raw source ───────────────────
    within "[data-testid=markdown-files]" do
      click_on "guide.md", match: :first
    end

    assert_selector "[data-testid=rendered-file] h1", text: "Guide"
    assert_selector "[data-testid=rendered-file] h2", text: "Section"
    assert_no_selector "[data-testid=rendered-file]", text: "# Guide"
  end

  test "a signed-out deep link redirects to sign in and returns you there once you're in" do
    sign_in_for_feature(@user)
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)

    find("[data-testid=account-menu] summary").click
    click_on "Sign out"
    assert_current_path sign_in_path
    assert_text "Review a pull request's Markdown"

    # Signed out now: the same URL bounces to sign-in instead of rendering.
    visit repo_pull_file_path(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    assert_current_path sign_in_path
    assert_selector "[data-testid=flash]", text: /sign in with github/i

    mock_github_auth(@user)
    click_on "Continue with GitHub"

    # The stored return-to is still the old per-file URL, which now redirects
    # into the Markdown tab — so this also proves an old bookmark survives.
    assert_selector "[data-testid=rendered-file]", minimum: 1
    assert_current_path repo_pull_markdown_path(owner: OWNER, repo: REPO, number: NUMBER)
  end
end
