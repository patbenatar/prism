# frozen_string_literal: true

require "test_helper"

module Review
  # Review::Page is the whole read path for the file view in one object: it
  # makes the GitHub calls, parses both sides of the file, and hands the view a
  # BlockMapper result. These tests drive it through WebMock the way a request
  # would, so a break here is a break on the screen.
  class PageTest < ActiveSupport::TestCase
    OWNER = "acme"
    REPO = "docs-site"
    NUMBER = 42
    HEAD_SHA = "6dcb09b5b57875f334f61aebed695e2e4193db5e"
    BASE_SHA = "1c2d3e4f5061728394a5b6c7d8e9f0a1b2c3d4e5"

    # The base side that actually produces the patch in pull_files.json.
    # It lives in a shared fixture so the head content, the patch and the
    # base cannot drift apart again — an inline copy of it did, and claimed
    # a base that the patch's second hunk could not have come from.
    def base_guide = github_fixture_raw("guide_base.md")

    setup do
      @user = users(:prism_dev)
      @github = Github::Client.new(@user)
    end

    # ------------------------------------------------------------ the file --

    test "it loads a modified file's head side and maps it against the diff" do
      page = load_guide

      assert_equal "docs/guide.md", page.file.path
      assert_predicate page, :markdown?
      assert_not page.no_patch?
      assert_not page.missing_content?
      assert_equal github_fixture_raw("guide.md"), page.head_source
      assert_equal base_guide, page.base_source
      assert_equal :right, page.result.side
    end

    test "it exposes only the pull request's Markdown files, in order" do
      page = load_guide

      assert_equal %w[docs/guide.md docs/troubleshooting.md docs/legacy.md docs/install.md],
                   page.files.map(&:path)
      assert_equal 0, page.file_index
      assert_nil page.prev_file
      assert_equal "docs/troubleshooting.md", page.next_file.path
    end

    test "the changed block count is the top-level blocks the pull request touched" do
      # The fixture contract pins these: blocks starting on lines 3 and 13.
      assert_equal 2, load_guide.changed_block_count
    end

    test "a path the pull request doesn't touch raises rather than rendering nothing" do
      stub_pull_request

      assert_raises(Page::FileNotFound) { load(path: "docs/nowhere.md") }
    end

    test "a non-Markdown path stops after the file list and offers its blob url" do
      stub_pull_request

      page = load(path: "assets/diagram.png")

      assert_not_predicate page, :markdown?
      assert_match %r{\Ahttps://github\.com/}, page.github_blob_url
      assert_nil page.result
      assert_github_not_requested(:post, "/graphql")
    end

    # --------------------------------------------------------- the threads --

    test "the five fixture threads land where the screen shows them" do
      page = load_guide

      assert_equal 1, page.result.file_threads.size
      assert_equal 1, page.result.outdated_threads.size
      assert_empty page.unattached_threads

      placed = page.result.all_blocks.select { |annotated| annotated.threads.any? }
      assert_equal 3, placed.sum { |annotated| annotated.threads.size }
    end

    test "the pending count covers the whole pull request, not just this file" do
      # The fixture's one PENDING comment is on docs/guide.md, but the count is
      # what the tray shows, and the tray speaks for the review as a whole.
      assert_equal 1, load_guide.pending_count
    end

    test "it finds the viewer's pending review and the pull request node id" do
      page = load_guide

      assert_equal "PR_kwDOABCD12MAAAABc9Vk", page.pull_request_node_id
      assert_predicate page.pending_review, :pending?
      assert_equal "prism-dev", page.pending_review.author.login
    end

    test "threads for another file are left out" do
      page = load_guide

      assert page.threads.all? { |thread| thread.path == "docs/guide.md" },
             "only this file's threads belong on this page"
    end

    test "a rate-limited threads call leaves the document readable" do
      stub_pull_request
      stub_contents("docs/guide.md", HEAD_SHA, github_fixture_raw("guide.md"))
      stub_contents("docs/guide.md", BASE_SHA, base_guide)
      stub_request(:post, "https://api.github.com/graphql")
        .to_return(status: 403, body: { message: "API rate limit exceeded" }.to_json,
                   headers: { "Content-Type" => "application/json", "X-RateLimit-Remaining" => "0" })

      page = load(path: "docs/guide.md")

      assert_predicate page, :rate_limited?
      assert_predicate page, :threads_unavailable?
      assert_empty page.threads
      assert page.result.blocks.size > 3, "the file still rendered"
    end

    test "GraphQL answering NOT_FOUND for the threads does not 404 the file" do
      # GraphQL returns NOT_FOUND in cases REST does not — a token that can read
      # the pull request but not query it that way. The pull request has already
      # loaded by the time we ask for threads, so a 404 here is about the
      # comments, and losing the whole screen over it would be wrong.
      stub_pull_request
      stub_contents("docs/guide.md", HEAD_SHA, github_fixture_raw("guide.md"))
      stub_contents("docs/guide.md", BASE_SHA, base_guide)
      stub_request(:post, "https://api.github.com/graphql")
        .to_return(status: 404, body: { message: "Not Found" }.to_json,
                   headers: { "Content-Type" => "application/json" })

      page = load(path: "docs/guide.md")

      assert_predicate page, :threads_unavailable?
      assert_not_predicate page, :rate_limited?
      assert_empty page.threads
      assert page.result.blocks.size > 3, "the file still rendered"
      # The node id has to come from somewhere, or every write would break.
      assert_equal "PR_kwDOABCD12MAAAABc9Vk", page.pull_request_node_id
    end

    # ------------------------------------------------------------ too big --

    test "a file over the size ceiling is refused before it is parsed" do
      stub_pull_request
      stub_contents("docs/guide.md", HEAD_SHA, oversized_markdown)
      stub_contents("docs/guide.md", BASE_SHA, base_guide)
      stub_threads

      page = load(path: "docs/guide.md")

      assert_predicate page, :missing_content?
      assert_equal :too_large, page.content_problem
      assert_predicate page, :too_large?
      assert_nil page.result, "nothing was parsed, sanitized or highlighted"
      assert_equal 0, page.changed_block_count
    end

    test "an oversized base side is refused too, since it is parsed as well" do
      stub_pull_request
      stub_contents("docs/guide.md", HEAD_SHA, github_fixture_raw("guide.md"))
      stub_contents("docs/guide.md", BASE_SHA, oversized_markdown)
      stub_threads

      page = load(path: "docs/guide.md")

      assert_predicate page, :too_large?
      assert_equal :too_large, page.content_problem
      assert_nil page.result
    end

    test "a file just under the ceiling still renders" do
      under = "# Title\n\n#{"word " * 10}\n"
      assert_operator under.bytesize, :<, Page::MAX_SOURCE_BYTES

      stub_pull_request
      stub_contents("docs/guide.md", HEAD_SHA, under)
      stub_contents("docs/guide.md", BASE_SHA, base_guide)
      stub_threads

      page = load(path: "docs/guide.md")

      assert_not_predicate page, :too_large?
      assert_nil page.content_problem
      assert_predicate page, :renderable?
    end

    test "a threads call that fails for another reason says so in GitHub's own words" do
      stub_pull_request
      stub_contents("docs/guide.md", HEAD_SHA, github_fixture_raw("guide.md"))
      stub_contents("docs/guide.md", BASE_SHA, base_guide)
      stub_request(:post, "https://api.github.com/graphql")
        .to_return(status: 500, body: { message: "Server Error" }.to_json,
                   headers: { "Content-Type" => "application/json" })

      page = load(path: "docs/guide.md")

      # Not a rate limit, so the page must not claim one — the two read
      # differently to a reviewer and only one of them ends at a known time.
      assert_not_predicate page, :rate_limited?
      assert_predicate page, :threads_unavailable?
      assert page.threads_error_message.present?
      assert page.result.blocks.size > 3, "the file still rendered"
    end

    # ------------------------------------------------------- the edge files --

    test "an added file has no base side and every block reads as added" do
      stub_pull_request
      stub_contents("docs/troubleshooting.md", HEAD_SHA,
                    "# Troubleshooting\n\nIf the build fails, check the log.\n")
      stub_threads

      page = load(path: "docs/troubleshooting.md")

      assert_nil page.base_source
      assert page.result.blocks.all?(&:added?), "an added file is all additions"
      assert page.result.blocks.all?(&:commentable?)
    end

    test "a removed file renders the base side and anchors to the left" do
      stub_pull_request
      stub_contents("docs/legacy.md", BASE_SHA, "# Legacy\n\nThis page is gone.\n")
      stub_threads

      page = load(path: "docs/legacy.md")

      assert_nil page.head_source
      assert_equal "# Legacy\n\nThis page is gone.\n", page.source
      assert_predicate page.result, :removed_file?
      assert_equal :left, page.result.side
      assert page.result.blocks.all?(&:commentable?),
             "the base lines are all in the diff, so LEFT anchors resolve"
      assert_equal [ :left ], page.result.blocks.map { |block| block.anchor.side }.uniq
    end

    test "a rename with no patch renders but anchors to nothing" do
      stub_pull_request
      stub_contents("docs/install.md", HEAD_SHA, "# Install\n\nRun the installer.\n")
      stub_contents("docs/installation.md", BASE_SHA, "# Install\n\nRun it.\n")
      stub_threads

      page = load(path: "docs/install.md")

      assert_predicate page, :no_patch?
      assert page.result.blocks.none?(&:commentable?)
      assert_equal [ :no_patch ], page.result.blocks.map(&:uncommentable_reason).uniq
      assert_equal 0, page.changed_block_count
    end

    test "a file GitHub won't serve reports missing content instead of an empty page" do
      stub_pull_request
      stub_request(:get, %r{/repos/#{OWNER}/#{REPO}/contents/docs/install(ation)?\.md})
        .to_return(status: 404, body: "{}", headers: { "Content-Type" => "application/json" })
      stub_threads

      page = load(path: "docs/install.md")

      assert_predicate page, :missing_content?
      assert_not_predicate page, :renderable?
      assert_nil page.result
      assert_equal 0, page.changed_block_count
    end

    test "a file whose bytes are binary is treated as unrenderable" do
      stub_pull_request
      stub_contents("docs/install.md", HEAD_SHA, "PK\u0000\u0000binary")
      stub_contents("docs/installation.md", BASE_SHA, "PK\u0000\u0000binary")
      stub_threads

      assert_predicate load(path: "docs/install.md"), :missing_content?
    end

    test "a diff with no deletions never asks GitHub for the base side" do
      # Nothing on the page uses the base file unless something was deleted, and
      # parsing it is the most expensive thing the page does.
      patch = "@@ -1,2 +1,3 @@\n # Title\n \n+A new line."
      stub_pull_request(files: [ file_json("docs/add.md", status: "modified", patch: patch) ])
      stub_contents("docs/add.md", HEAD_SHA, "# Title\n\nA new line.\n")
      stub_threads(threads: [])

      page = load(path: "docs/add.md")

      assert_nil page.base_source
      assert_github_not_requested(:get, "/repos/#{OWNER}/#{REPO}/contents/docs/add.md",
                                  query: hash_including({ "ref" => BASE_SHA }))
      assert_equal 1, page.changed_block_count
    end

    # ------------------------------------------------------ removed strips --

    # The shared fixture's patch has no base block that is deleted outright, so
    # this one builds a pull request that does: a whole paragraph disappears
    # between two that stay.
    test "a base block deleted outright becomes a strip before the block that replaced it" do
      head = "# Title\n\nKept paragraph.\n\nTail paragraph.\n"
      base = "# Title\n\nDoomed paragraph.\n\nKept paragraph.\n\nTail paragraph.\n"
      patch = "@@ -1,7 +1,5 @@\n # Title\n \n-Doomed paragraph.\n-\n Kept paragraph.\n \n Tail paragraph."

      stub_pull_request(files: [ file_json("docs/strip.md", status: "modified", patch: patch) ])
      stub_contents("docs/strip.md", HEAD_SHA, head)
      stub_contents("docs/strip.md", BASE_SHA, base)
      stub_threads(threads: [])

      page = load(path: "docs/strip.md")
      with_strip = page.result.blocks.select(&:removed_before?)

      assert_equal 1, with_strip.size
      assert_equal "Kept paragraph.", with_strip.first.block.plain_text
      assert_equal [ "Doomed paragraph." ], with_strip.first.removed_before.map(&:plain_text)
      assert_predicate with_strip.first, :modified?
    end

    # ------------------------------------------------------------- linking --

    test "the permalink base is the head blob, which is what a file comment quotes" do
      page = load_guide

      assert_equal "https://github.com/acme/docs-site/blob/#{HEAD_SHA}/docs/guide.md",
                   page.file_comment_permalink_base
      assert_equal "https://github.com/acme/docs-site/pull/42/files", page.source_diff_url
    end

    private

    def load(path:)
      Page.load(github: @github, owner: OWNER, repo: REPO, number: NUMBER, path: path)
    end

    def load_guide
      stub_pull_request
      stub_contents("docs/guide.md", HEAD_SHA, github_fixture_raw("guide.md"))
      stub_contents("docs/guide.md", BASE_SHA, base_guide)
      stub_threads
      stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", fixture: :reviews)

      load(path: "docs/guide.md")
    end

    def stub_pull_request(files: nil)
      stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
      if files
        stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/files", body: files)
      else
        stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/files", fixture: :pull_files)
      end
    end

    def stub_threads(threads: nil)
      if threads.nil?
        stub_github_graphql(:ReviewThreads, fixture: :review_threads)
      else
        stub_github_graphql(:ReviewThreads, data: {
          repository: { pullRequest: { id: "PR_kwDOABCD12MAAAABc9Vk",
                                       reviewThreads: { pageInfo: { hasNextPage: false, endCursor: nil },
                                                        nodes: threads } } }
        })
      end
      stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", fixture: :reviews)
    end

    def stub_contents(path, ref, body)
      stub_github_raw_get("/repos/#{OWNER}/#{REPO}/contents/#{path}",
                          body: body, query: hash_including({ "ref" => ref }))
    end

    # Just over the ceiling, and real Markdown rather than one long line, so a
    # failure to refuse it would actually cost the parse we are avoiding.
    def oversized_markdown
      @oversized_markdown ||= "# Big\n\n#{"A sentence of prose. " * 80_000}\n"
    end

    def file_json(path, status:, patch:, previous: nil)
      {
        "filename" => path, "status" => status, "additions" => 1, "deletions" => 2,
        "changes" => 3, "patch" => patch, "previous_filename" => previous,
        "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{path}"
      }.compact
    end
  end
end
