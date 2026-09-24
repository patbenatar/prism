# frozen_string_literal: true

require "test_helper"

# The Markdown tab's read path: every renderable `.md` file in the pull
# request, on one page.
#
# The fixtures are the shared ones (four Markdown files, docs/guide.md with a
# two-hunk patch and five review threads covering RIGHT / LEFT / outdated /
# FILE / PENDING), so these tests and
# test/services/review/github_fixture_contract_test.rb are describing the same
# document from two ends.
class PullRequestFilesTest < ActionDispatch::IntegrationTest
  OWNER = "acme"
  REPO  = "docs-site"
  NUMBER = 42
  PATH = "docs/guide.md"
  HEAD_SHA = "6dcb09b5b57875f334f61aebed695e2e4193db5e"
  BASE_SHA = "1c2d3e4f5061728394a5b6c7d8e9f0a1b2c3d4e5"

  # The pull request's four Markdown files, in the order the file list gives
  # them — which is the order they appear on the page.
  MARKDOWN_PATHS = %w[docs/guide.md docs/troubleshooting.md docs/legacy.md docs/install.md].freeze

  setup { @user = users(:prism_dev) }

  # The base side of docs/guide.md, shared with test/services/review and with
  # the fixture contract test: lines 1-3 survive into the head file, line 14 is
  # the one this pull request rewrites, and line 17 is deleted from the end of
  # the file with nothing after it to sit before.
  def base_guide = github_fixture_raw("guide_base.md")

  # ------------------------------------------------------------------ auth --

  test "signed out, the Markdown tab sends you to sign in" do
    get markdown_path

    assert_redirected_to sign_in_path
  end

  # ------------------------------------------------------- one page, all files --

  test "every Markdown file in the pull request is on the page, in the file list's order" do
    sign_in_and_stub

    get markdown_path

    assert_response :success
    assert_select "[data-testid=file-section]", MARKDOWN_PATHS.size
    assert_equal MARKDOWN_PATHS, css_select("[data-testid=file-section]").map { |s| s["data-file-path"] }
    assert_equal MARKDOWN_PATHS.map { |path| Review::Page.file_key(path) },
                 css_select("[data-testid=file-section]").map { |section| section["id"] },
                 "each section is the anchor a link to that file scrolls to"

    # The non-Markdown file in the fixture stays on GitHub.
    assert_select "[data-file-path='assets/diagram.png']", 0
  end

  test "the whole page costs exactly one reviewThreads call, however many files it holds" do
    sign_in_and_stub

    get markdown_path

    assert_response :success
    threads_calls = github_graphql_requests.count { |request| request[:operation] == "ReviewThreads" }
    assert_equal 1, threads_calls,
                 "one GraphQL threads query for the page, not one per file"
  end

  test "each file gets its own sticky heading with status and diffstat" do
    sign_in_and_stub

    get markdown_path

    assert_select "[data-testid=file-head]", MARKDOWN_PATHS.size
    within_file(PATH) do
      assert_select "[data-testid=file-head]", text: /guide\.md/
      assert_select "[data-testid=file-head]", text: /Modified/
      assert_select "[data-testid=file-head]", text: /\+4/
    end
    within_file("docs/legacy.md") { assert_select "[data-testid=file-head]", text: /Removed/ }
  end

  # ------------------------------------------------------------- the document --

  test "it renders each file's blocks with the data the commenting seam needs" do
    sign_in_and_stub

    get markdown_path

    assert_response :success
    assert_select "[data-testid=rendered-file]", MARKDOWN_PATHS.size

    within_file(PATH) do
      assert_select "[data-testid=md-block]", minimum: 5
      # The heading of the document is really rendered, not escaped source.
      assert_select ".md-body.md-prose h1", text: "Guide"
      assert_select ".md-body.md-prose h2", text: "Section"

      assert_select "div.md-block[id^=block_][data-block-id]", minimum: 5
      assert_select "div[id^=threads_]", minimum: 5
      assert_select "div[id^=composer_]", minimum: 5
    end
  end

  test "changed blocks are marked and unchanged ones are left alone" do
    sign_in_and_stub

    get markdown_path

    within_file(PATH) do
      # The contract test pins these: blocks starting on lines 3 and 13 contain
      # added lines; the rest of the document did not change.
      assert_select "[data-testid=md-block][data-change=added]", 2
      assert_select "[data-testid=md-block][data-change=added].md-block--added", 2
      assert_select "[data-testid=md-block][data-change=unchanged]", minimum: 1
    end
    assert_select ".md-block--unchanged", 0
  end

  test "the gutter button carries the anchor the composer will post" do
    sign_in_and_stub

    get markdown_path

    button = css_select("##{key(PATH)} [data-testid=md-block][data-change=added] .md-add").first
    assert button, "a changed block should offer a + button"
    assert_equal "true", button["data-commentable"]
    assert_equal "composer#open", button["data-action"]
    assert_equal PATH, button["data-path"], "the button knows which file it is in"

    anchor = JSON.parse(button["data-anchor"])
    assert_equal PATH, anchor["path"]
    assert_equal "RIGHT", anchor["side"]
    assert_equal "line", anchor["subject_type"]
    assert anchor["line"].is_a?(Integer), "the anchor needs a line: #{anchor.inspect}"
  end

  test "a block outside the diff still offers a muted + and says why" do
    sign_in_and_stub

    get markdown_path

    muted = css_select("##{key(PATH)} [data-testid=md-block][data-commentable=false] .md-add").first
    assert muted, "blocks between the hunks are outside the diff"
    assert_includes muted["class"], "md-add--muted"
    assert_equal "outside_diff", muted["data-uncommentable-reason"]
    assert_nil muted["data-anchor"], "an uncommentable block has no anchor to post"
    assert_match "isn't part of the PR diff", muted["title"]
  end

  test "every id on the page is unique across every file it holds" do
    # Two hazards at once. Nested list items can start on the same source line,
    # which used to give two elements one id. And Markdown::Renderer numbers
    # blocks from zero *per document*, so two files sharing a first heading
    # produce the same block id — which only became a collision when the page
    # started holding every file.
    sign_in_and_stub
    colliding = <<~MARKDOWN
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
    stub_contents(PATH, HEAD_SHA, colliding)
    # Byte-identical content in a second file: same blocks, same renderer
    # counter, same unprefixed ids.
    stub_contents("docs/troubleshooting.md", HEAD_SHA, colliding)

    get markdown_path

    assert_response :success
    # `<template>` content is an inert fragment in a browser and contributes
    # no ids to the document, but Nokogiri parses it inline — so skip it, the
    # same way the DOM does.
    ids = css_select("[id]").reject { |node| node.ancestors("template").any? }
                            .map { |node| node["id"] }.grep(/\A(block|threads|composer)_/)

    assert_operator ids.size, :>=, 28, "both files' children should be on the page"
    assert_equal ids.uniq, ids,
                 "duplicated: #{ids.tally.select { |_, count| count > 1 }.keys.inspect}"

    hosts = css_select("li[data-block-id], tr[data-block-id]").map { |n| n["data-block-id"] }
    assert_equal hosts.uniq, hosts, "no two elements may claim the same block"
    assert_equal hosts.size, css_select("li > .md-add--child, tr .md-add--row").size,
                 "every child element that claims a block also offers its own +"
  end

  # ------------------------------------------------------- folding a file away --

  test "each file heading carries the control that folds the file away" do
    sign_in_and_stub

    get markdown_path

    MARKDOWN_PATHS.each do |path|
      toggle = css_select("##{key(path)} [data-testid=file-toggle]").first
      assert toggle, "#{path} needs a disclosure control in its heading"
      assert_equal "true", toggle["aria-expanded"], "every file starts open"
      assert_equal "body_#{key(path)}", toggle["aria-controls"]
      assert_equal "filehead-#{key(path)}", toggle["aria-labelledby"],
                   "the control is named by the file it folds, not by a bare chevron"
    end

    assert_select "#body_#{key(PATH)}", 1, "the control has something to point at"
  end

  # --------------------------------------------- folding what didn't change --

  test "a long untouched stretch of a modified file folds into an expander" do
    sign_in_and_stub
    stub_contents(PATH, HEAD_SHA, long_document)
    stub_contents(PATH, BASE_SHA, long_document.sub("Paragraph 1.", "The old first line."))

    get markdown_path

    within_file(PATH) do
      assert_select "[data-testid=unchanged-run]", minimum: 1
      assert_select "[data-testid=unchanged-run] summary", text: /\d+ unchanged blocks/
      # `<details>`, not something removed from the page: the blocks inside
      # are ordinary DOM, so every id still resolves and every "+" still works
      # the moment it opens.
      assert_select "[data-testid=unchanged-run][open]", 0, "it starts folded"
      assert_select "[data-testid=unchanged-run] [data-testid=md-block]", minimum: 3
    end
  end

  test "a run holding a comment is never folded away" do
    sign_in_and_stub
    stub_contents(PATH, HEAD_SHA, long_document)
    stub_contents(PATH, BASE_SHA, long_document.sub("Paragraph 1.", "The old first line."))
    # A thread on line 25 — deep inside what would otherwise fold whole.
    stub_github_graphql(:ReviewThreads, data: threads_data_on_line(25))

    get markdown_path

    thread = css_select("#thread_PRRT_deep").first
    assert thread, "the thread should be on the page at all"
    assert_equal 0, thread.ancestors("details[data-testid=unchanged-run]").size,
                 "a hidden comment is a lost comment"
  end

  test "an added file has no unchanged parts, so nothing folds" do
    sign_in_and_stub
    stub_contents("docs/troubleshooting.md", HEAD_SHA,
                  "# Troubleshooting\n\nIf the build fails, check the log.\n")

    get markdown_path

    within_file("docs/troubleshooting.md") do
      assert_select "[data-testid=md-block][data-change=added]", 2
      assert_select "[data-testid=md-block][data-change=unchanged]", 0
      assert_select "[data-testid=unchanged-run]", 0
    end
  end

  test "a file GitHub sent no diff for is shown whole rather than folded away" do
    # Every block is unchanged, so "fold what didn't change" would fold the
    # whole document. The reviewer opened it to read it.
    sign_in_and_stub
    stub_contents("docs/install.md", HEAD_SHA, long_document)

    get markdown_path

    within_file("docs/install.md") do
      assert_select "[data-testid=md-block]", minimum: 10
      assert_select "[data-testid=unchanged-run]", 0
    end
  end

  # ---------------------------------------------------------------- threads --

  test "an existing RIGHT-side thread renders under the block it belongs to" do
    sign_in_and_stub

    get markdown_path

    assert_select "[data-testid=thread]", minimum: 1
    assert_match "This paragraph repeats the heading above", response.body

    # Thread PRRT_…AA1 is on line 3, the block the patch added.
    thread = css_select("#thread_PRRT_kwDOABCD12MAAAAAAA1").first
    assert thread, "the line-3 thread should be on the page"
    assert_match(/\Athreads_#{key(PATH)}-/, thread.parent["id"])
  end

  test "a file-level thread goes to the top of its own file, not the top of the page" do
    sign_in_and_stub

    get markdown_path

    within_file(PATH) do
      assert_select "[data-testid=file-threads] [data-testid=thread]", 1
      assert_select "[data-testid=file-threads-section]", text: /Comments on this file/
    end

    container = css_select("##{"file_threads_#{key(PATH)}"}").first
    assert container, "the container is keyed by file, so a write can target it"
    assert_equal PATH, container["data-file-threads-for"]
    assert_select "#file_threads", 0, "the page-wide id is gone; there are four files now"
  end

  test "an outdated thread goes to the end of its own file with its original line and hunk" do
    sign_in_and_stub

    get markdown_path

    section = "##{"outdated_threads_#{key(PATH)}"}"
    assert_select section
    assert_select "#{section} [data-testid=outdated-thread]", minimum: 1
    assert_select "#{section} [data-testid=diff-hunk]", minimum: 1
    assert_select section, text: /Left on line\s*42/
  end

  test "the pending comment is counted once in the tray, for the whole pull request" do
    sign_in_and_stub

    get markdown_path

    assert_select "#pending_tray", 1
    assert_select "#pending_tray [data-testid=pending-count]", text: /1 pending comment/
  end

  # -------------------------------------------------------------- the seam --

  test "each file's section carries its own composer context, including the viewer" do
    # This is the seam with the commenting workstream (PLAN.md "Phase 2
    # seam"). It moved from `#file_view` onto each file's section, because
    # `path` and the permalink base are per file now — and because an element
    # inside two scopes of the same Stimulus identifier fires twice.
    sign_in_and_stub

    get markdown_path

    section = css_select("##{key(PATH)}").first
    assert section, "the composer controller needs a root to attach to"

    assert_includes section["data-controller"].split, "composer"
    assert_equal "composer_template_#{key(PATH)}", section["data-composer-template-id"]
    assert_equal OWNER, section["data-composer-owner"]
    assert_equal REPO, section["data-composer-repo"]
    assert_equal NUMBER.to_s, section["data-composer-number"]
    assert_equal PATH, section["data-composer-path"]
    assert_equal HEAD_SHA, section["data-composer-head-sha"]
    assert_equal "PR_kwDOABCD12MAAAABc9Vk", section["data-composer-pull-request-node-id"]
    assert_equal "right", section["data-composer-side"]
    assert_equal "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{PATH}",
                 section["data-composer-file-comment-permalink-base"]

    # The viewer, for the provisional card the composer shows while a comment
    # is in flight.
    assert_equal @user.login, section["data-composer-viewer-login"]
    assert_equal @user.avatar_url, section["data-composer-viewer-avatar"]
  end

  test "each file gets its own composer template, because the path differs per file" do
    sign_in_and_stub

    get markdown_path

    MARKDOWN_PATHS.each do |path|
      template = css_select("template#composer_template_#{key(path)}").first
      assert template, "#{path} needs a composer template of its own"
      path_field = template.css("input[name=path]").first
      assert path_field, "#{path}'s template needs the hidden path field"
      assert_equal path, path_field["value"], "each template posts its own file's path"
    end
  end

  test "no two composer scopes nest, so no action fires twice" do
    sign_in_and_stub

    get markdown_path

    css_select("[data-controller~=composer]").each do |scope|
      assert_equal 0, scope.css("[data-controller~=composer]").size,
                   "a composer scope inside another would bind every action twice"
    end
  end

  # ---------------------------------------------------------- browser title --

  test "both tabs of a pull request carry the same title, most specific first" do
    # The actual requirement, and one no screenshot can show: moving along a
    # tab strip must not rewrite the window title, because nothing changed.
    sign_in_and_stub
    stub_github_markdown(body: "<p>A description.</p>")

    get repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)
    overview = title_of(response.body)

    get markdown_path
    markdown = title_of(response.body)

    assert_equal overview, markdown
    assert_equal "Rewrite the getting-started guide #42 · acme/docs-site · Prism", markdown
    assert_no_match(/markdown/i, markdown,
                    "which tab you are on is on screen; it does not belong in a bookmark")
  end

  test "the pull request list leads with what it is, then where" do
    sign_in_as_user
    stub_github_get("/repos/#{OWNER}/#{REPO}", fixture: :repo)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls", fixture: :pulls)

    get repo_pulls_path(owner: OWNER, repo: REPO)

    assert_equal "Pull requests · acme/docs-site · Prism", title_of(response.body)
  end

  # -------------------------------------------------------- tabs and the bar --

  test "the tab strip names both screens and marks this one" do
    sign_in_and_stub

    get markdown_path

    assert_select "[data-testid=pr-tabs]"
    assert_select "[data-testid=tab-overview][href=?]", repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)
    assert_select "[data-testid=tab-markdown].tab-active"
    assert_select "[data-testid=tab-markdown][aria-current=page]"
    assert_select "[data-testid=tab-markdown]", text: /Markdown\s*4/
    assert_select "[data-testid=tab-overview]", text: /Overview\s*5/
  end

  test "the file switcher is a jump menu: fragment links, not navigation" do
    sign_in_and_stub

    get markdown_path

    assert_select "[data-testid=file-bar]"
    items = css_select("[data-testid=file-switcher-item]")
    assert_equal MARKDOWN_PATHS.map { |path| "##{key(path)}" }, items.map { |item| item["href"] }
    assert_select "[data-testid=prev-file]", 0, "there is nowhere left to navigate to"
    assert_select "[data-testid=next-file]", 0
  end

  test "the bar counts the changed blocks in the whole pull request and links to the source diff" do
    sign_in_and_stub

    get markdown_path

    assert_select "[data-testid=source-diff-on-github][href=?]",
                  "https://github.com/acme/docs-site/pull/42/files"
    # Two in docs/guide.md, two in the added docs/troubleshooting.md, two in
    # the deleted docs/legacy.md; docs/install.md has no patch.
    assert_select "[data-testid=changed-count]", text: /6 changed blocks/
  end

  # ------------------------------------------------------- the old per-file URL --

  test "the per-file URL redirects to the page, anchored at that file" do
    sign_in_and_stub

    get repo_pull_file_path(owner: OWNER, repo: REPO, number: NUMBER, path: "docs/troubleshooting.md")

    assert_redirected_to repo_pull_markdown_path(owner: OWNER, repo: REPO, number: NUMBER,
                                                 anchor: key("docs/troubleshooting.md"))
  end

  test "the per-file URL costs no more than the file list to redirect" do
    sign_in_and_stub

    get repo_pull_file_path(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)

    assert_response :redirect
    assert_github_not_requested(:post, "/graphql")
    assert_github_not_requested(:get, "/repos/#{OWNER}/#{REPO}/contents/#{PATH}")
  end

  test "a file the pull request doesn't touch renders the friendly 404" do
    sign_in_and_stub

    get repo_pull_file_path(owner: OWNER, repo: REPO, number: NUMBER, path: "docs/nowhere.md")

    assert_response :not_found
    assert_select "[data-testid=empty-state]"
  end

  test "a non-Markdown file redirects to GitHub rather than rendering" do
    sign_in_and_stub

    get repo_pull_file_path(owner: OWNER, repo: REPO, number: NUMBER, path: "assets/diagram.png")

    assert_redirected_to %r{\Ahttps://github\.com/}
  end

  # ------------------------------------------------------------ edge states --

  test "content deleted from the end of a file renders in a strip after its last block" do
    # Base line 17 is deleted with nothing after it, so it has no following
    # head block to sit before. Dropping it would tell the reviewer the
    # paragraph is still in the file.
    sign_in_and_stub

    get markdown_path

    assert_response :success
    within_file(PATH) do
      assert_select "[data-testid=removed-strip]", 1
      assert_select "[data-testid=removed-strip]", text: /Deprecated note\./
      assert_select "[data-testid=removed-strip]", text: /1 block removed/
      assert_select "[data-testid=removed-strip] .md-add", 0,
                    "deleted lines have no RIGHT side to anchor to"
      assert_select "[data-testid=removed-strip]", text: /Deleted content can't take a new comment/
    end
  end

  test "a file GitHub sent no diff for renders with a banner and nothing anchored" do
    sign_in_and_stub
    stub_contents("docs/install.md", HEAD_SHA, "# Install\n\nRun the installer.\n")

    get markdown_path

    assert_response :success
    within_file("docs/install.md") do
      assert_select "[data-testid=uncommentable-notice][data-kind=no_patch]"
      assert_select ".md-add", minimum: 1
      assert_select ".md-add:not(.md-add--muted)", 0
      assert_select "[data-testid=md-block][data-commentable=true]", 0
    end
  end

  test "a file this pull request deletes renders the base side, marked removed" do
    sign_in_and_stub
    stub_contents("docs/legacy.md", BASE_SHA, "# Legacy\n\nThis page is gone.\n")

    get markdown_path

    assert_response :success
    within_file("docs/legacy.md") do
      assert_select "[data-testid=uncommentable-notice][data-kind=file_removed]"
      assert_select "[data-testid=md-block][data-change=removed]", 2
      assert_select ".md-block--removed", 2
      assert_select "[data-testid=rendered-file]", text: /This page is gone/
    end
  end

  test "an added file is all added blocks" do
    sign_in_and_stub
    stub_contents("docs/troubleshooting.md", HEAD_SHA,
                  "# Troubleshooting\n\nIf the build fails, check the log.\n")

    get markdown_path

    assert_response :success
    within_file("docs/troubleshooting.md") do
      assert_select "[data-testid=md-block][data-change=added]", 2
      assert_select "[data-testid=md-block][data-change=unchanged]", 0
    end
  end

  test "a file GitHub won't serve falls back to a link, and the rest of the page still renders" do
    sign_in_and_stub
    stub_request(:get, "https://api.github.com/repos/#{OWNER}/#{REPO}/contents/docs/install.md")
      .with(query: hash_including({})).to_return(status: 404, body: "{}",
                                                 headers: { "Content-Type" => "application/json" })

    get markdown_path

    assert_response :success
    within_file("docs/install.md") do
      assert_select "[data-testid=uncommentable-notice][data-kind=missing_content]"
      assert_select "[data-testid=empty-state]"
      assert_select "[data-testid=md-block]", 0
    end
    within_file(PATH) { assert_select "[data-testid=md-block]", minimum: 5 }
  end

  test "a file over the size ceiling says so and links out instead of parsing it" do
    sign_in_and_stub
    stub_contents(PATH, HEAD_SHA, "# Big\n\n#{"A sentence of prose. " * 80_000}\n")

    get markdown_path

    assert_response :success
    within_file(PATH) do
      assert_select "[data-testid=uncommentable-notice][data-kind=too_large]"
      assert_select "[data-testid=empty-state]"
      assert_select "[data-testid=md-block]", 0
      assert_select "[data-testid=view-on-github]"
    end
    assert_no_match "A sentence of prose", response.body
  end

  test "one file's fetch failing leaves the other files on the page, with a reason on that one" do
    sign_in_and_stub
    stub_request(:get, "https://api.github.com/repos/#{OWNER}/#{REPO}/contents/docs/troubleshooting.md")
      .with(query: hash_including({}))
      .to_return(status: 500, body: { message: "Server Error" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    get markdown_path

    assert_response :success, "one bad fetch must not take the page down"
    within_file("docs/troubleshooting.md") do
      assert_select "[data-testid=uncommentable-notice][data-kind=unavailable]"
      assert_select "[data-testid=empty-state]", text: /GitHub didn't send this file/
      assert_select "[data-testid=md-block]", 0
    end
    within_file(PATH) { assert_select "[data-testid=md-block]", minimum: 5 }
    assert_select "[data-testid=rate-limit-banner]", 0, "a 500 is not a rate limit"
  end

  test "a rate-limited file raises the page banner and still renders every other file" do
    sign_in_and_stub
    stub_request(:get, "https://api.github.com/repos/#{OWNER}/#{REPO}/contents/docs/troubleshooting.md")
      .with(query: hash_including({}))
      .to_return(status: 403, body: { message: "API rate limit exceeded" }.to_json,
                 headers: { "Content-Type" => "application/json", "X-RateLimit-Remaining" => "0" })

    get markdown_path

    assert_response :success
    assert_select "[data-testid=rate-limit-banner]", 1
    within_file("docs/troubleshooting.md") do
      assert_select "[data-testid=uncommentable-notice][data-kind=unavailable]"
    end
    within_file(PATH) { assert_select "[data-testid=md-block]", minimum: 5 }
  end

  test "past the rendering budget a file is still listed, with a link and a reason" do
    sign_in_and_stub

    with_render_budget(40) { get markdown_path }

    assert_response :success
    assert_select "[data-testid=file-section]", MARKDOWN_PATHS.size, "every file keeps its heading"
    assert_select "[data-testid=file-switcher-item]", MARKDOWN_PATHS.size, "and its place in the jump menu"

    within_file(PATH) { assert_select "[data-testid=md-block]", minimum: 5 }
    within_file("docs/troubleshooting.md") do
      assert_select "[data-testid=uncommentable-notice][data-kind=deferred]"
      assert_select "[data-testid=empty-state]", text: /Not rendered on this page/
      assert_select "[data-testid=md-block]", 0
      assert_select "a[href^=?]", "https://github.com/"
    end
  end

  test "a pull request with no Markdown says so instead of rendering nothing" do
    sign_in_as_user
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/files",
                    body: [ { filename: "assets/diagram.png", status: "modified",
                              additions: 0, deletions: 0,
                              blob_url: "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/assets/diagram.png" } ])
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", fixture: :reviews)
    stub_github_graphql(:ReviewThreads, fixture: :review_threads)

    get markdown_path

    assert_response :success
    assert_select "[data-testid=empty-state]", text: /No Markdown in this pull request/
    assert_select "[data-testid=file-section]", 0
  end

  # ----------------------------------------------------------- degraded data --

  test "GraphQL answering NOT_FOUND for the threads leaves every document readable" do
    sign_in_and_stub(threads: false)
    stub_request(:post, "https://api.github.com/graphql")
      .to_return(status: 404, body: { message: "Not Found" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    get markdown_path

    assert_response :success, "a 404 on the comments must not 404 the page"
    assert_select "[data-testid=threads-unavailable]", 1
    assert_select "[data-testid=file-section]", MARKDOWN_PATHS.size
    assert_select "[data-testid=thread]", 0
  end

  test "a rate-limited threads call still renders the documents, with one banner" do
    sign_in_and_stub(threads: false)
    stub_request(:post, "https://api.github.com/graphql")
      .to_return(status: 403,
                 body: { message: "API rate limit exceeded" }.to_json,
                 headers: { "Content-Type" => "application/json",
                            "X-RateLimit-Remaining" => "0" })

    get markdown_path

    assert_response :success
    assert_select "[data-testid=rate-limit-banner]", 1
    assert_select "[data-testid=thread]", 0
    within_file(PATH) { assert_select "[data-testid=md-block]", minimum: 5 }
  end

  test "threads failing for a reason other than a rate limit says so in GitHub's words" do
    sign_in_and_stub(threads: false)
    stub_request(:post, "https://api.github.com/graphql")
      .to_return(status: 500, body: { message: "Server Error" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    get markdown_path

    assert_response :success
    assert_select "[data-testid=threads-unavailable]"
    assert_select "[data-testid=rate-limit-banner]", 0, "a 500 is not a rate limit"
    within_file(PATH) { assert_select "[data-testid=md-block]", minimum: 5 }
  end

  test "a pull request that doesn't exist renders the friendly 404" do
    sign_in_as_user
    stub_github_error(:get, "/repos/#{OWNER}/#{REPO}/pulls/999", status: 404, message: "Not Found")

    get markdown_path(number: 999)

    assert_response :not_found
  end

  private

  def markdown_path(number: NUMBER)
    repo_pull_markdown_path(owner: OWNER, repo: REPO, number: number)
  end

  def key(path) = Review::Page.file_key(path)

  def title_of(body) = Nokogiri::HTML5(body).at_css("title").text

  # Long enough that a single edit at the top leaves runs worth folding.
  def long_document
    "# Title\n\n" + (1..30).map { |n| "Paragraph #{n}." }.join("\n\n") + "\n"
  end

  # One live thread, in the shape the reviewThreads query answers with.
  def threads_data_on_line(line)
    comment = {
      id: "PRRC_deep", databaseId: 918_273, body: "Deep in the untouched middle.",
      bodyHTML: "<p>Deep in the untouched middle.</p>", state: "SUBMITTED",
      createdAt: "2026-09-19T10:00:00Z",
      url: "https://github.com/#{OWNER}/#{REPO}/pull/#{NUMBER}#discussion_r918273",
      diffHunk: "", outdated: false, viewerCanUpdate: false, viewerCanDelete: false,
      viewerCanReact: true,
      author: { login: "octocat", avatarUrl: "https://example.com/a.png",
                url: "https://github.com/octocat" },
      replyTo: nil, reactionGroups: []
    }

    { repository: { pullRequest: {
      id: "PR_kwDOABCD12MAAAABc9Vk",
      reviewThreads: { pageInfo: { hasNextPage: false, endCursor: nil }, nodes: [ {
        id: "PRRT_deep", path: PATH, line: line, originalLine: line,
        startLine: nil, originalStartLine: nil, diffSide: "RIGHT", startDiffSide: nil,
        subjectType: "LINE", isResolved: false, isOutdated: false,
        viewerCanResolve: true, viewerCanUnresolve: false, viewerCanReply: true,
        resolvedBy: nil,
        comments: { pageInfo: { hasNextPage: false, endCursor: nil }, nodes: [ comment ] }
      } ] }
    } } }
  end

  def with_render_budget(bytes)
    original = Review::PullRequestPage::RENDER_BUDGET_BYTES
    silence_warnings { Review::PullRequestPage.const_set(:RENDER_BUDGET_BYTES, bytes) }
    yield
  ensure
    silence_warnings { Review::PullRequestPage.const_set(:RENDER_BUDGET_BYTES, original) }
  end

  # Scopes the assertions in the block to one file's section, which is what
  # almost every per-file assertion means now that four of them share a page.
  def within_file(path, &block)
    section = css_select("##{key(path)}").first
    assert section, "#{path} should have a section on the page"
    assert_select section, "*", &block
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

    # The page fetches every Markdown file, so every Markdown file needs an
    # answer. This is the fallback; the specific stubs below (and any a test
    # adds) are registered later and WebMock prefers the newest match.
    stub_request(:get, %r{\Ahttps://api\.github\.com/repos/#{OWNER}/#{REPO}/contents/})
      .with(query: hash_including({}))
      .to_return(status: 200, body: "# Another file\n\nA paragraph of prose.\n\nAnd a second one.\n",
                 headers: { "Content-Type" => "text/plain; charset=utf-8" })

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
