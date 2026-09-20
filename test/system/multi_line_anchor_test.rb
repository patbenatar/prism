# frozen_string_literal: true

require "application_system_test_case"

# Test gap flagged by the independent review (2026-09-19): "Multi-line
# anchors are never posted" / never shown through a browser. The shared
# docs/guide.md fixture's second hunk makes head lines 13-18 a contiguous
# in-diff run, and lines 15-18 ("Prose here." / "New line." / "Another." /
# "Tail.") are one paragraph block, so it is the one block in the shared
# fixture that resolves to a genuine multi-line Review::Anchor
# (start_line: 15, line: 18) rather than a single line — see
# test/integration/review_comments_controller_test.rb for the same block
# exercised at the controller level.
#
# This is its own file rather than an addition to test/system/commenting_test.rb
# because that file already uses docs/guide.md as its path with its own,
# unrelated HEAD/PATCH content stubbed for a different block — reusing the
# class would mean re-stubbing every one of those requests to avoid
# colliding with the shared fixture used here.
class MultiLineAnchorTest < ApplicationSystemTestCase
  OWNER = "acme"
  REPO = "docs-site"
  NUMBER = 42
  PATH = "docs/guide.md"
  HEAD_SHA = "6dcb09b5b57875f334f61aebed695e2e4193db5e"
  BASE_SHA = "1c2d3e4f5061728394a5b6c7d8e9f0a1b2c3d4e5"

  # test/integration/pull_request_files_test.rb's own base fixture, kept in
  # sync with it: the removed-strip/LEFT-side placement this exercises is not
  # this test's concern, only that the head side (guide.md, unchanged by
  # this) yields the multi-line block.
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

    # System tests share one browser session (`parallelize(workers: 1)`);
    # don't inherit a phone-width window left over from another test.
    page.driver.browser.manage.window.resize_to(1440, 900)

    stub_github_get("/user/repos", fixture: :repos)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/files", fixture: :pull_files)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", fixture: :reviews)
    # The review screen holds every Markdown file in the pull request; the
    # other three are not this test's concern, but they still need answers.
    stub_request(:get, %r{\Ahttps://api\.github\.com/repos/#{OWNER}/#{REPO}/contents/})
      .with(query: hash_including({}))
      .to_return(status: 200, body: "# Another file\n\nProse.\n",
                 headers: { "Content-Type" => "text/plain; charset=utf-8" })
    stub_github_raw_get("/repos/#{OWNER}/#{REPO}/contents/#{PATH}", body: github_fixture_raw("guide.md"),
                        query: hash_including({ "ref" => HEAD_SHA }))
    stub_github_raw_get("/repos/#{OWNER}/#{REPO}/contents/#{PATH}", body: BASE_GUIDE,
                        query: hash_including({ "ref" => BASE_SHA }))
    stub_github_graphql(:ReviewThreads, fixture: :review_threads)
  end

  test "the multi-line block shows the full range in the composer, not just its last line" do
    sign_in_as(@user)
    visit repo_pull_markdown_path(owner: OWNER, repo: REPO, number: NUMBER,
                                  anchor: Review::Page.file_key(PATH))
    assert_selector "[data-testid=rendered-file]", minimum: 1

    block = find("##{Review::Page.file_key(PATH)} [data-testid=md-block][data-start-line='15']")
    assert_equal "18", block["data-end-line"], "docs/guide.md's second hunk should still make this one paragraph block"
    assert_equal "true", block["data-commentable"]

    block_id = block["data-block-id"]
    block.hover
    block.find(".md-add").click

    # The composer does not narrate the range any more (W4: the reviewer chose
    # the block by clicking it). What has to be true is that the whole range
    # reached the form, because that is what gets sent to GitHub.
    within "#composer_#{block_id}" do
      assert_equal "15", find("[data-composer-target=startLine]", visible: false).value
      assert_equal "18", find("[data-composer-target=line]", visible: false).value
    end
  end
end
