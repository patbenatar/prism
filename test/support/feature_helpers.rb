# frozen_string_literal: true

# Journey-level helpers shared by test/system/features/*_test.rb.
#
# The per-endpoint stubbing primitives (`stub_github_get`, `stub_github_graphql`,
# `assert_github_graphql`, `github_request_body`, ...) already live in
# GithubStubs and are exactly right — this module does not wrap them, it only
# adds the things every *feature* test repeats: a stable cast (owner/repo/PR),
# builders for the GraphQL review-thread shape so a test can describe "one
# resolved thread on line 11" without retyping the whole node, sequenced
# responses for the two endpoints whose shape changes mid-journey
# (review_threads, pending-review reads), and the handful of DOM interactions
# every write journey performs (open the composer, type into it, submit it).
#
# Loaded by test_helper.rb's `Dir[Rails.root.join("test/support/**/*.rb")]`
# glob, alongside GithubStubs and AuthenticationHelpers, so every test case
# already has it mixed in.
module FeatureHelpers
  FEATURE_OWNER = "acme"
  FEATURE_REPO = "docs-site"
  FEATURE_NUMBER = 42
  FEATURE_HEAD_SHA = "6dcb09b5b57875f334f61aebed695e2e4193db5e"
  FEATURE_BASE_SHA = "1c2d3e4f5061728394a5b6c7d8e9f0a1b2c3d4e5"
  FEATURE_PR_NODE_ID = "PR_kwDOABCD12MAAAABc9Vk"

  # ------------------------------------------------------------- fixtures ---

  def feature_fixture_path(name)
    Rails.root.join("test/fixtures/github/features", name.to_s)
  end

  def feature_fixture_raw(name) = File.read(feature_fixture_path(name))

  # ------------------------------------------------------------------ auth --

  # Signs in the given (or default) fixture user through the real OmniAuth
  # test-mode flow, the way every journey starts. Signing in with no stored
  # return-to path lands on root, which redirects to /repos — stub that read
  # (idempotent: WebMock is fine with the same stub registered twice) so a
  # journey that never otherwise visits /repos doesn't 500 on the way through.
  def sign_in_for_feature(user = users(:prism_dev))
    stub_github_get("/user/repos", fixture: :repos)
    sign_in_as(user)
    user
  end

  # ------------------------------------------------------------- REST world --

  # The handful of GitHub calls almost every journey makes before it ever
  # touches a file: the viewer's repo list (only fetched if the journey visits
  # /repos or the top bar's breadcrumb links back there), the PR itself, its
  # files, and its reviews. `files_body` defaults to the shared fixture but a
  # journey building its own document/patch passes its own JSON.
  def stub_feature_pull_request(owner: FEATURE_OWNER, repo: FEATURE_REPO, number: FEATURE_NUMBER,
                                 pull_fixture: :pull, files_body: nil, files_fixture: nil,
                                 reviews_fixture: :reviews, reviews_body: nil)
    stub_github_get("/repos/#{owner}/#{repo}/pulls/#{number}", fixture: pull_fixture)

    if files_body
      stub_github_get("/repos/#{owner}/#{repo}/pulls/#{number}/files", body: files_body)
    else
      stub_github_get("/repos/#{owner}/#{repo}/pulls/#{number}/files", fixture: files_fixture || :pull_files)
    end

    if reviews_body
      stub_github_get("/repos/#{owner}/#{repo}/pulls/#{number}/reviews", body: reviews_body)
    else
      stub_github_get("/repos/#{owner}/#{repo}/pulls/#{number}/reviews", fixture: reviews_fixture)
    end

    stub_feature_other_contents(owner: owner, repo: repo)
  end

  # The review screen renders *every* Markdown file in the pull request on one
  # page, so every Markdown file needs an answer from the contents endpoint —
  # including the ones a given journey does not care about. This is the floor.
  # A journey's own `stub_feature_contents` is registered after it and WebMock
  # prefers the most recently declared match, so naming a file still wins.
  def stub_feature_other_contents(owner: FEATURE_OWNER, repo: FEATURE_REPO, body: nil)
    stub_request(:get, %r{\Ahttps://api\.github\.com/repos/#{owner}/#{repo}/contents/})
      .with(query: hash_including({}))
      .to_return(status: 200,
                 body: body || "# Another file\n\nA paragraph of prose.\n\nAnd another one.\n",
                 headers: { "Content-Type" => "text/plain; charset=utf-8" })
  end

  # Raw file contents on a given ref. `ref` is required, matching the actual
  # query GitHub gets asked (?ref=<sha>) so HEAD and BASE stubs never collide.
  def stub_feature_contents(path, ref, body, owner: FEATURE_OWNER, repo: FEATURE_REPO)
    stub_github_raw_get("/repos/#{owner}/#{repo}/contents/#{path}", body: body,
                        query: hash_including({ "ref" => ref }))
  end

  # @-mention autocomplete's two reads. Every composer on the page fetches
  # this once (mention_controller.js caches it across the page's lifetime).
  def stub_feature_mentionables(owner: FEATURE_OWNER, repo: FEATURE_REPO)
    stub_github_get("/repos/#{owner}/#{repo}/collaborators", fixture: :collaborators)
    stub_github_get("/orgs/#{owner}/members", fixture: :org_members)
  end

  # The `#` autocomplete's one read. Same shape of convenience as
  # `stub_feature_mentionables`: a test that types a `#` anywhere in a comment
  # needs this, because the browser will go and ask.
  def stub_feature_references(owner: FEATURE_OWNER, repo: FEATURE_REPO, fixture: :issues, body: nil)
    if body
      stub_github_get("/repos/#{owner}/#{repo}/issues", body: body)
    else
      stub_github_get("/repos/#{owner}/#{repo}/issues", fixture: fixture)
    end
  end

  # ---------------------------------------------------------- GraphQL world --

  # One GraphQL `reviewThreads` node, in the exact shape
  # test/fixtures/github/review_threads.json uses. A test builds a scenario by
  # calling this once per thread it wants on the page.
  def feature_thread(node_id:, path:, comments:, line: nil, original_line: line,
                      start_line: nil, original_start_line: start_line,
                      diff_side: "RIGHT", start_diff_side: (start_line ? diff_side : nil),
                      subject_type: "LINE", resolved: false, outdated: false,
                      viewer_can_resolve: !resolved, viewer_can_unresolve: resolved,
                      viewer_can_reply: true, resolved_by: nil)
    {
      id: node_id, path: path, line: line, originalLine: original_line,
      startLine: start_line, originalStartLine: original_start_line,
      diffSide: diff_side, startDiffSide: start_diff_side, subjectType: subject_type,
      isResolved: resolved, isOutdated: outdated,
      viewerCanResolve: viewer_can_resolve, viewerCanUnresolve: viewer_can_unresolve,
      viewerCanReply: viewer_can_reply, resolvedBy: resolved_by,
      comments: { pageInfo: { hasNextPage: false, endCursor: nil }, nodes: comments }
    }
  end

  # One comment inside a `feature_thread`'s `comments:`.
  def feature_comment(node_id:, body:, state: "SUBMITTED", author_login: "octocat",
                       author_avatar: "https://avatars.githubusercontent.com/u/583231?v=4",
                       database_id: rand(900_000..999_999), diff_hunk: "", outdated: false,
                       viewer_can_update: false, viewer_can_delete: false, viewer_can_react: !pending?(state),
                       reply_to: nil, reaction_groups: [], created_at: "2026-09-19T10:00:00Z",
                       owner: FEATURE_OWNER, repo: FEATURE_REPO, number: FEATURE_NUMBER)
    {
      id: node_id, databaseId: database_id, body: body, bodyHTML: "<p>#{ERB::Util.html_escape(body)}</p>",
      state: state, createdAt: created_at,
      url: "https://github.com/#{owner}/#{repo}/pull/#{number}#discussion_r#{database_id}",
      diffHunk: diff_hunk, outdated: outdated,
      viewerCanUpdate: viewer_can_update, viewerCanDelete: viewer_can_delete, viewerCanReact: viewer_can_react,
      author: { login: author_login, avatarUrl: author_avatar, url: "https://github.com/#{author_login}" },
      replyTo: reply_to, reactionGroups: reaction_groups
    }
  end

  def pending?(state) = state.to_s == "PENDING"

  # `reviewThreads` answers with a *sequence* of node lists as a journey
  # progresses (a fresh comment, then a pending review, then a second draft):
  # each matching request gets the next list in order, and the last repeats
  # for anything further. A single-list call is just a sequence of one.
  def stub_feature_review_threads(*node_sets, pr_node_id: FEATURE_PR_NODE_ID)
    responses = node_sets.map do |nodes|
      {
        status: 200,
        body: { data: { repository: { pullRequest: {
          id: pr_node_id,
          reviewThreads: { pageInfo: { hasNextPage: false, endCursor: nil }, nodes: nodes }
        } } } }.to_json,
        headers: GithubStubs::JSON_HEADERS
      }
    end

    stub_request(:post, "#{GithubStubs::API}/graphql")
      .with { |request| graphql_operation_name(request.body) == "ReviewThreads" }
      .to_return(*responses)
  end

  # `GET .../reviews` answers with a sequence too — a pending review appears
  # partway through a journey once the reviewer starts one.
  def stub_feature_reviews_sequence(*review_lists, owner: FEATURE_OWNER, repo: FEATURE_REPO, number: FEATURE_NUMBER)
    responses = review_lists.map do |list|
      { status: 200, body: (list.is_a?(String) ? list : list.to_json), headers: GithubStubs::JSON_HEADERS }
    end

    stub_request(:get, "#{GithubStubs::API}/repos/#{owner}/#{repo}/pulls/#{number}/reviews")
      .with(query: hash_including({}))
      .to_return(*responses)
  end

  # A longer journey (start a review, add drafts across two files, reload,
  # submit) makes an unpredictable *number* of reads of `reviewThreads` and
  # `.../reviews` — Page#load reads both once per file view, and every write
  # re-reads them again to render the tray — so pinning a fixed sequence of
  # canned responses is fragile (off by one and a later step silently reads
  # the wrong snapshot). These two read from a shared, mutable `state` Hash
  # (`{ reviews: [...], threads: [...] }`) instead, so every read always
  # reflects whatever the test has told it happened so far, independent of
  # exactly how many times GitHub gets asked. `state` is a plain Hash the test
  # owns and mutates directly (`state[:threads] << thread`); combine with
  # `stub_feature_create_pending_review_dynamic`, which keeps `state[:reviews]`
  # itself in sync the moment GitHub "creates" the review.
  def stub_feature_reviews_dynamic(state, owner: FEATURE_OWNER, repo: FEATURE_REPO, number: FEATURE_NUMBER)
    stub_request(:get, "#{GithubStubs::API}/repos/#{owner}/#{repo}/pulls/#{number}/reviews")
      .with(query: hash_including({}))
      .to_return { { status: 200, body: Array(state[:reviews]).to_json, headers: GithubStubs::JSON_HEADERS } }
  end

  def stub_feature_review_threads_dynamic(state, pr_node_id: FEATURE_PR_NODE_ID)
    stub_request(:post, "#{GithubStubs::API}/graphql")
      .with { |request| graphql_operation_name(request.body) == "ReviewThreads" }
      .to_return do
        {
          status: 200,
          body: { data: { repository: { pullRequest: {
            id: pr_node_id,
            reviewThreads: { pageInfo: { hasNextPage: false, endCursor: nil }, nodes: Array(state[:threads]) }
          } } } }.to_json,
          headers: GithubStubs::JSON_HEADERS
        }
      end
  end

  # Keeps `state[:reviews]` in sync the moment GitHub answers a
  # `POST .../reviews` (opening the pending review) — pairs with
  # `stub_feature_reviews_dynamic` above.
  def stub_feature_create_pending_review_dynamic(state, owner: FEATURE_OWNER, repo: FEATURE_REPO,
                                                  number: FEATURE_NUMBER, fixture: :pending_review)
    stub_request(:post, "#{GithubStubs::API}/repos/#{owner}/#{repo}/pulls/#{number}/reviews")
      .to_return do
        review = github_fixture(fixture)
        state[:reviews] = [ review ]
        { status: 201, body: review.to_json, headers: GithubStubs::JSON_HEADERS }
      end
  end

  # A single `addPullRequestReviewThread` response that pushes `thread` into
  # `state[:threads]` at the moment the request actually arrives, not when
  # the test sets this stub up. That distinction matters the instant a full
  # page load (a file switch, a reload) sits between registering the stub and
  # the click that triggers it: `Page#load` reads `state[:threads]` for real
  # on that load, so mutating eagerly makes it see a comment that, from the
  # app's point of view, hasn't been created yet — one call too early. This
  # is the GraphQL-mutation counterpart to
  # `stub_feature_create_pending_review_dynamic`'s REST one.
  def stub_feature_add_thread_dynamic(state, thread)
    stub_request(:post, "#{GithubStubs::API}/graphql")
      .with { |request| graphql_operation_name(request.body) == "AddThread" }
      .to_return do
        state[:threads] << thread
        {
          status: 200,
          body: { data: { addPullRequestReviewThread: { thread: thread } } }.to_json,
          headers: GithubStubs::JSON_HEADERS
        }
      end
  end

  # ------------------------------------------------------------------ DOM ---

  # Visits the Markdown tab, scrolled to `path`, and waits for that file's
  # section to be there. Returns the section, so a journey that needs to be
  # unambiguous about which file it is acting on can scope to it:
  #
  #   within(open_pull_file(path: PATH)) { ... }
  #
  # Every Markdown file in the pull request is on this one page now, so a bare
  # `find(".md-add")` is a page-wide search — fine when the text is unique,
  # wrong when it is a count or a `first`.
  def open_pull_file(owner: FEATURE_OWNER, repo: FEATURE_REPO, number: FEATURE_NUMBER, path:)
    visit repo_pull_markdown_path(owner: owner, repo: repo, number: number,
                                  anchor: Review::Page.file_key(path))
    assert_selector "[data-testid=rendered-file]"
    file_section(path)
  end

  # One file's section on the Markdown tab.
  def file_section(path)
    find("##{Review::Page.file_key(path)}")
  end

  # The container a file's file-level threads render into.
  def file_threads_id(path) = "file_threads_#{Review::Page.file_key(path)}"

  # Hovers a block and clicks its "+", the way a reviewer reaches the composer.
  def open_composer_for(block)
    block.hover
    block.find(".md-add", match: :first).click
    block["data-block-id"]
  end

  # Types into whichever composer/reply/edit textarea is open inside `within_id`.
  def type_into_composer(within_id, text)
    within "##{within_id}" do
      area = find("textarea", match: :first)
      area.click
      area.send_keys(text)
    end
  end

  # Opens a block's composer, types `body`, and submits it either as a single
  # comment (default) or into the pending review. Returns the block id, so a
  # caller can assert on `#composer_<id>` / `#threads_<id>` afterward.
  def comment_on_block(block, body:, review: false)
    block_id = open_composer_for(block)

    within "#composer_#{block_id}" do
      area = find("textarea", match: :first)
      area.click
      area.send_keys(body)
      click_on(review ? /\A(Start a review|Add review comment)\z/ : "Add single comment")
    end

    block_id
  end

  # ---------------------------------------------------------- assertions ---

  # A single seam for "GitHub received the write we expect": for a GraphQL
  # operation, delegates to GithubStubs#assert_github_graphql (block receives
  # the mutation's `variables`); for a REST call, fetches and returns the
  # parsed JSON body of the last request to `path` so the caller can assert on
  # it directly (or hand a block that does).
  #
  #   expect_github_received(:AddThread) { |vars| vars["input"]["line"] == 3 }
  #   body = expect_github_received(:post, "/repos/acme/docs-site/pulls/42/reviews/80002/events")
  def expect_github_received(operation_or_method, path = nil, message = nil, &block)
    if path.nil?
      assert_github_graphql(operation_or_method, message, &block)
    else
      body = github_request_body(operation_or_method, path)
      assert(block.call(body), message || "request body did not match: #{body.inspect}") if block
      body
    end
  end
end
