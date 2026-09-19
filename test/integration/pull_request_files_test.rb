# frozen_string_literal: true

require "test_helper"

# The rendered file view's read path.
#
# The fixtures are the shared ones (docs/guide.md with a two-hunk patch, five
# review threads covering RIGHT / LEFT / outdated / FILE / PENDING), so these
# tests and test/services/review/github_fixture_contract_test.rb are describing
# the same document from two ends.
class PullRequestFilesTest < ActionDispatch::IntegrationTest
  OWNER = "acme"
  REPO  = "docs-site"
  NUMBER = 42
  PATH = "docs/guide.md"
  HEAD_SHA = "6dcb09b5b57875f334f61aebed695e2e4193db5e"
  BASE_SHA = "1c2d3e4f5061728394a5b6c7d8e9f0a1b2c3d4e5"

  setup { @user = users(:prism_dev) }

  # The base side of docs/guide.md, shared with test/services/review and with
  # the fixture contract test: lines 1-3 survive into the head file, line 14 is
  # the one this pull request rewrites, and line 17 is deleted from the end of
  # the file with nothing after it to sit before.
  def base_guide = github_fixture_raw("guide_base.md")

  # ------------------------------------------------------------------ auth --

  test "signed out, the file view sends you to sign in" do
    get file_path

    assert_redirected_to sign_in_path
  end

  # ------------------------------------------------------------- the screen --

  test "it renders the file's blocks with the data the commenting seam needs" do
    sign_in_and_stub

    get file_path

    assert_response :success
    assert_select "[data-testid=rendered-file]"
    assert_select "[data-testid=md-block]", minimum: 5

    # The heading of the document is really rendered, not escaped source.
    assert_select ".md-body.md-prose h1", text: "Guide"
    assert_select ".md-body.md-prose h2", text: "Section"

    # Every block carries an id and a block id, and each has its two slots.
    assert_select "div.md-block[id^=block_][data-block-id]", minimum: 5
    assert_select "div[id^=threads_]", minimum: 5
    assert_select "div[id^=composer_]", minimum: 5
  end

  test "changed blocks are marked and unchanged ones are left alone" do
    sign_in_and_stub

    get file_path

    # The contract test pins these: blocks starting on lines 3 and 13 contain
    # added lines; the rest of the document did not change.
    assert_select "[data-testid=md-block][data-change=added]", 2
    assert_select "[data-testid=md-block][data-change=added].md-block--added", 2
    assert_select "[data-testid=md-block][data-change=unchanged]", minimum: 1
    assert_select ".md-block--unchanged", 0
  end

  test "the gutter button carries the anchor the composer will post" do
    sign_in_and_stub

    get file_path

    button = css_select("[data-testid=md-block][data-change=added] .md-add").first
    assert button, "a changed block should offer a + button"
    assert_equal "true", button["data-commentable"]
    assert_equal "composer#open", button["data-action"]

    anchor = JSON.parse(button["data-anchor"])
    assert_equal PATH, anchor["path"]
    assert_equal "RIGHT", anchor["side"]
    assert_equal "line", anchor["subject_type"]
    assert anchor["line"].is_a?(Integer), "the anchor needs a line: #{anchor.inspect}"
  end

  test "a block outside the diff still offers a muted + and says why" do
    sign_in_and_stub

    get file_path

    muted = css_select("[data-testid=md-block][data-commentable=false] .md-add").first
    assert muted, "blocks between the hunks are outside the diff"
    assert_includes muted["class"], "md-add--muted"
    assert_equal "outside_diff", muted["data-uncommentable-reason"]
    assert_nil muted["data-anchor"], "an uncommentable block has no anchor to post"
    assert_match "isn't part of the PR diff", muted["title"]
  end

  test "an existing RIGHT-side thread renders under the block it belongs to" do
    sign_in_and_stub

    get file_path

    assert_select "[data-testid=thread]", minimum: 1
    assert_match "This paragraph repeats the heading above", response.body

    # Thread PRRT_…AA1 is on line 3, the block the patch added.
    thread = css_select("#thread_PRRT_kwDOABCD12MAAAAAAA1").first
    assert thread, "the line-3 thread should be on the page"
    assert_match(/\Athreads_/, thread.parent["id"])
  end

  test "a file-level thread goes to the top of the file" do
    sign_in_and_stub

    get file_path

    assert_select "#file_threads [data-testid=thread]", 1
    assert_select ".file-threads", text: /Comments on this file/
  end

  test "an outdated thread goes to the bottom with its original line and hunk" do
    sign_in_and_stub

    get file_path

    assert_select "#outdated_threads"
    assert_select "#outdated_threads [data-testid=outdated-thread]", minimum: 1
    assert_select "#outdated_threads [data-testid=diff-hunk]", minimum: 1
    assert_select "#outdated_threads", text: /Left on line\s*42/
  end

  test "the pending comment is counted in the tray" do
    sign_in_and_stub

    get file_path

    # The tray itself is workstream E's; what D owes it is the count, and it
    # counts PENDING comments across the whole pull request, not this file.
    assert_select "#pending_tray [data-testid=pending-count]", text: /1 pending comment/
  end

  test "every block, thread slot and composer slot on the page has a unique id" do
    # Nested list items can start on the same source line, which is the case
    # that used to give two elements one id — and with it one gutter, and a
    # comment on the inner item appending into the outer item's container.
    sign_in_and_stub
    stub_contents(PATH, HEAD_SHA, <<~MARKDOWN)
      # Guide

      - - a one-line nested item
      1. - sharing line four
         - and its sibling

      | A | B |
      | --- | --- |
      | 1 | 2 |

      - outer
        - inner
    MARKDOWN

    get file_path

    assert_response :success
    ids = css_select("[id]").map { |node| node["id"] }.grep(/\A(block|threads|composer)_/)

    assert_operator ids.size, :>=, 14, "the fixture needs enough children to be worth checking"
    assert_equal ids.uniq, ids,
                 "duplicated: #{ids.tally.select { |_, count| count > 1 }.keys.inspect}"

    hosts = css_select("li[data-block-id], tr[data-block-id]").map { |n| n["data-block-id"] }
    assert_equal hosts.uniq, hosts, "no two elements may claim the same block"
    assert_equal hosts.size, css_select("li > .md-add--child, tr .md-add--row").size,
                 "every child element that claims a block also offers its own +"
  end

  # ------------------------------------------------------------- the top bar --

  test "the file bar lists every Markdown file and links out to GitHub" do
    sign_in_and_stub

    get file_path

    assert_select "[data-testid=file-bar]"
    assert_select "[data-testid=file-switcher-item]", 4   # the fixture's four .md files
    assert_select "[data-testid=view-on-github][href^=?]", "https://github.com/"
    assert_select "[data-testid=source-diff-on-github][href=?]",
                  "https://github.com/acme/docs-site/pull/42/files"
    assert_select "[data-testid=changed-count]", text: /2 changed blocks/
  end

  test "prev and next walk the pull request's Markdown files" do
    sign_in_and_stub

    get file_path

    # docs/guide.md is first, so there is a next file and no previous one.
    assert_select "[data-testid=prev-file]", 0
    assert_select "[data-testid=next-file][href=?]",
                  repo_pull_file_path(owner: OWNER, repo: REPO, number: NUMBER,
                                      path: "docs/troubleshooting.md")
  end

  # ------------------------------------------------------------ edge states --

  test "content deleted from the end of the file renders in a strip after the last block" do
    # Base line 17 is deleted with nothing after it, so it has no following
    # head block to sit before. Dropping it would tell the reviewer the
    # paragraph is still in the file.
    sign_in_and_stub

    get file_path

    assert_response :success
    strips = css_select("[data-testid=removed-strip]")
    assert_equal 1, strips.size

    assert_select "[data-testid=removed-strip]", text: /Deprecated note\./
    assert_select "[data-testid=removed-strip]", text: /1 block removed/

    # After the document, not inside it — it is the end of the file.
    body = response.body
    assert_operator body.index("Deprecated note."), :>, body.rindex("data-testid=\"md-block\""),
                    "the trailing strip comes after the last block"
  end

  test "a trailing removed strip is not commentable and says where to comment instead" do
    sign_in_and_stub

    get file_path

    assert_select "[data-testid=removed-strip] .md-add", 0,
                  "deleted lines have no RIGHT side to anchor to"
    assert_select "[data-testid=removed-strip]", text: /Deleted content can't take a new comment/
  end

  test "a file the pull request doesn't touch renders the friendly 404" do
    sign_in_and_stub

    get file_path(path: "docs/nowhere.md")

    assert_response :not_found
    assert_select "[data-testid=empty-state]"
  end

  test "a non-Markdown file redirects to GitHub rather than rendering" do
    sign_in_and_stub

    get file_path(path: "assets/diagram.png")

    assert_redirected_to %r{\Ahttps://github\.com/}
  end

  test "a file GitHub sent no diff for renders with a banner and nothing anchored" do
    sign_in_and_stub
    stub_contents("docs/install.md", HEAD_SHA, "# Install\n\nRun the installer.\n")
    stub_contents("docs/installation.md", BASE_SHA, "# Install\n\nRun the installer.\n")

    get file_path(path: "docs/install.md")

    assert_response :success
    assert_select "[data-testid=uncommentable-notice][data-kind=no_patch]"
    assert_select ".md-add", minimum: 1
    assert_select ".md-add:not(.md-add--muted)", 0
    assert_select "[data-testid=md-block][data-commentable=true]", 0
  end

  test "a file this pull request deletes renders the base side, marked removed" do
    sign_in_and_stub
    stub_contents("docs/legacy.md", BASE_SHA, "# Legacy\n\nThis page is gone.\n")

    get file_path(path: "docs/legacy.md")

    assert_response :success
    assert_select "[data-testid=uncommentable-notice][data-kind=file_removed]"
    assert_select "[data-testid=md-block][data-change=removed]", minimum: 2
    assert_select ".md-block--removed", minimum: 2
    assert_match "This page is gone", response.body
  end

  test "an added file is all added blocks" do
    sign_in_and_stub
    stub_contents("docs/troubleshooting.md", HEAD_SHA,
                  "# Troubleshooting\n\nIf the build fails, check the log.\n")

    get file_path(path: "docs/troubleshooting.md")

    assert_response :success
    assert_select "[data-testid=md-block][data-change=added]", 2
    assert_select "[data-testid=md-block][data-change=unchanged]", 0
  end

  test "a file GitHub won't serve falls back to a link instead of a blank page" do
    sign_in_and_stub
    stub_request(:get, "https://api.github.com/repos/#{OWNER}/#{REPO}/contents/docs/install.md")
      .with(query: hash_including({})).to_return(status: 404, body: "{}",
                                                 headers: { "Content-Type" => "application/json" })
    stub_request(:get, "https://api.github.com/repos/#{OWNER}/#{REPO}/contents/docs/installation.md")
      .with(query: hash_including({})).to_return(status: 404, body: "{}",
                                                 headers: { "Content-Type" => "application/json" })

    get file_path(path: "docs/install.md")

    assert_response :success
    assert_select "[data-testid=uncommentable-notice][data-kind=missing_content]"
    assert_select "[data-testid=empty-state]"
    assert_select "[data-testid=md-block]", 0
  end

  test "a file over the size ceiling says so and links out instead of parsing it" do
    sign_in_and_stub
    stub_contents(PATH, HEAD_SHA, "# Big\n\n#{"A sentence of prose. " * 80_000}\n")

    get file_path

    assert_response :success
    assert_select "[data-testid=uncommentable-notice][data-kind=too_large]"
    assert_select "[data-testid=empty-state]"
    assert_select "[data-testid=md-block]", 0
    assert_select "[data-testid=view-on-github]"
    assert_no_match "A sentence of prose", response.body
  end

  test "GraphQL answering NOT_FOUND for the threads leaves the document readable" do
    sign_in_and_stub(threads: false)
    stub_request(:post, "https://api.github.com/graphql")
      .to_return(status: 404, body: { message: "Not Found" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    get file_path

    assert_response :success, "a 404 on the comments must not 404 the file"
    assert_select "[data-testid=threads-unavailable]"
    assert_select "[data-testid=md-block]", minimum: 5
    assert_select "[data-testid=thread]", 0
  end

  test "a rate-limited threads call still renders the document, with a banner" do
    sign_in_and_stub(threads: false)
    stub_request(:post, "https://api.github.com/graphql")
      .to_return(status: 403,
                 body: { message: "API rate limit exceeded" }.to_json,
                 headers: { "Content-Type" => "application/json",
                            "X-RateLimit-Remaining" => "0" })

    get file_path

    assert_response :success
    assert_select "[data-testid=rate-limit-banner]"
    assert_select "[data-testid=md-block]", minimum: 5
    assert_select "[data-testid=thread]", 0
  end

  test "threads failing for a reason other than a rate limit says so in GitHub's words" do
    sign_in_and_stub(threads: false)
    stub_request(:post, "https://api.github.com/graphql")
      .to_return(status: 500, body: { message: "Server Error" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    get file_path

    assert_response :success
    assert_select "[data-testid=threads-unavailable]"
    assert_select "[data-testid=rate-limit-banner]", 0, "a 500 is not a rate limit"
    assert_select "[data-testid=md-block]", minimum: 5
  end

  test "a pull request that doesn't exist renders the friendly 404" do
    sign_in_as_user
    stub_github_error(:get, "/repos/#{OWNER}/#{REPO}/pulls/999", status: 404, message: "Not Found")

    get file_path(number: 999)

    assert_response :not_found
  end

  private

  def file_path(path: PATH, number: NUMBER)
    repo_pull_file_path(owner: OWNER, repo: REPO, number: number, path: path)
  end

  def sign_in_as_user
    stub_github_get("/user/repos", fixture: :repos)
    sign_in_as(@user)
  end

  def sign_in_and_stub(threads: true)
    sign_in_as_user
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/files", fixture: :pull_files)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", fixture: :reviews)
    stub_contents(PATH, HEAD_SHA, github_fixture_raw("guide.md"))
    stub_contents(PATH, BASE_SHA, base_guide)
    stub_github_graphql(:ReviewThreads, fixture: :review_threads) if threads
  end

  # The contents endpoint answers with raw bytes, and the ref decides which
  # side of the pull request you get.
  def stub_contents(path, ref, body)
    stub_github_raw_get("/repos/#{OWNER}/#{REPO}/contents/#{path}",
                        body: body, query: hash_including({ "ref" => ref }))
  end
end
