# frozen_string_literal: true

require "application_system_test_case"

# Journey 6: where existing threads land on the page, using the shared
# fixture (test/fixtures/github/review_threads.json) that carries one thread
# of each kind — RIGHT, LEFT (on removed content), outdated, FILE, and a
# multi-line PENDING draft — against docs/guide.md
# (test/fixtures/github/pull_files.json, test/fixtures/github/guide.md). The
# same fixtures back test/integration/pull_request_files_test.rb and
# test/services/review/github_fixture_contract_test.rb, so this journey is
# the same document proven a third way, through a real browser.
class ThreadPlacementTest < ApplicationSystemTestCase
  include FeatureHelpers

  OWNER = FeatureHelpers::FEATURE_OWNER
  REPO = FeatureHelpers::FEATURE_REPO
  NUMBER = FeatureHelpers::FEATURE_NUMBER
  PATH = "docs/guide.md"
  HEAD_SHA = FeatureHelpers::FEATURE_HEAD_SHA
  BASE_SHA = FeatureHelpers::FEATURE_BASE_SHA

  # The base side of docs/guide.md, consistent with pull_files.json's patch:
  # lines 1-3 survive into the head file, line 11 is the one this PR deletes.
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

    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER)
    stub_feature_mentionables(owner: OWNER, repo: REPO)
    stub_github_markdown(fixture: "markdown.html")
    stub_feature_contents(PATH, HEAD_SHA, github_fixture_raw("guide.md"), owner: OWNER, repo: REPO)
    stub_feature_contents(PATH, BASE_SHA, BASE_GUIDE, owner: OWNER, repo: REPO)
    stub_github_graphql(:ReviewThreads, fixture: :review_threads)

    sign_in_for_feature(@user)
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
  end

  test "a RIGHT-side thread renders directly under the block it belongs to" do
    thread = find("#thread_PRRT_kwDOABCD12MAAAAAAA1")
    assert_text thread, "This paragraph repeats the heading above"

    # Its parent is that block's own threads container, not a catch-all bucket.
    assert_match(/\Athreads_/, thread.find(:xpath, "..")["id"])
  end

  test "a LEFT-side thread on removed content shows the muted badge and sits near the removed strip" do
    thread = find("#thread_PRRT_kwDOABCD12MAAAAAAA2")
    assert_text thread, "On removed content"

    # This fixture thread is also resolved, so its comments are collapsed
    # behind "Show the resolved conversation" until opened.
    thread.find("summary").click
    assert_text thread, "Why was this line removed?"
  end

  test "an outdated thread collapses into the bottom section with its original line and hunk" do
    assert_selector "#outdated_threads"
    # The section is a closed <details> by default (DESIGN.md screen 5:
    # "Outdated section at the bottom"), so its content has no layout box
    # until opened.
    find("#outdated_threads summary").click

    within "#outdated_threads" do
      assert_selector "[data-testid=outdated-thread]", text: /Left on line\s*42/
      assert_selector "[data-testid=diff-hunk]", text: /old example/
      assert_text "This example no longer compiles."
    end
  end

  test "a FILE-level thread renders at the top of the file, in the file threads section" do
    within ".file-threads" do
      assert_text "Comments on this file"
      assert_selector "#file_threads [data-testid=thread]", text: "This whole section sits outside the diff"
    end
  end

  test "a multi-line PENDING thread shows the Pending badge and counts toward the tray" do
    thread = find("#thread_PRRT_kwDOABCD12MAAAAAAA5")
    assert_text thread, "Draft note on the new lines, not submitted yet."
    assert_selector thread, ".pill-pending", text: "Pending"

    assert_selector "#pending_tray [data-testid=pending-count]", text: "1 pending comment"
  end
end
