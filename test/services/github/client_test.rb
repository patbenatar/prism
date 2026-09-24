# frozen_string_literal: true

require "test_helper"

# Every test here stubs GitHub at the HTTP layer and asserts on the request we
# actually sent — URL, query, headers, JSON body, GraphQL operation and
# variables — not just on the value that came back. A client that returns the
# right object from the wrong request is the failure mode worth catching.
class Github::ClientTest < ActiveSupport::TestCase
  setup do
    @user = users(:prism_dev)
    @client = Github::Client.new(@user)
  end

  # A stand-in for Review::Anchor, which Workstream B owns. The client only ever
  # asks an anchor for to_graphql/to_rest, so this is the whole contract.
  Anchor = Struct.new(:graphql, :rest) do
    def to_graphql = graphql
    def to_rest = rest
  end

  def line_anchor(path: "docs/guide.md", line: 3, side: "RIGHT")
    Anchor.new({ path: path, line: line, side: side, subjectType: "LINE" },
               { path: path, line: line, side: side })
  end

  def file_anchor(path: "docs/guide.md")
    Anchor.new({ path: path, subjectType: "FILE" }, { path: path, subject_type: "file" })
  end

  # ---------------------------------------------------------------- reads ---

  test "viewer maps GET /user onto an Author" do
    stub_github_get("/user", fixture: :viewer)

    author = @client.viewer

    assert_equal "prism-dev", author.login
    assert_equal "https://github.com/prism-dev", author.html_url
    assert_equal "https://avatars.githubusercontent.com/u/4242?v=4", author.avatar_url
    assert_github_requested :get, "/user"
  end

  test "repos asks for the most recently pushed first" do
    stub_github_get("/user/repos", fixture: :repos)

    repos = @client.repos

    assert_equal %w[acme/docs-site prism-dev/scratchpad], repos.map(&:full_name)
    assert_github_requested :get, "/user/repos",
                     query: { "sort" => "pushed", "direction" => "desc", "per_page" => "100", "page" => "1" }
  end

  test "repos maps owner details and organization-ness" do
    stub_github_get("/user/repos", fixture: :repos)

    org_repo, user_repo = @client.repos

    assert_equal "acme", org_repo.owner
    assert_equal "Organization", org_repo.owner_type
    assert org_repo.organization?
    assert org_repo.private?
    assert_equal 7, org_repo.open_issues_count
    assert_equal Time.utc(2026, 9, 18, 14, 2, 11), org_repo.pushed_at

    assert_not user_repo.organization?
    assert_not user_repo.private?
    assert_nil user_repo.description
  end

  test "repos passes the requested page through" do
    stub_github_get("/user/repos", body: [])

    @client.repos(page: 3)

    assert_github_requested :get, "/user/repos", query: hash_including("page" => "3")
  end

  test "repo fetches a single repository" do
    stub_github_get("/repos/acme/docs-site", fixture: :repo)

    repo = @client.repo("acme", "docs-site")

    assert_equal "acme/docs-site", repo.full_name
    assert_equal "main", repo.default_branch
  end

  test "pull_requests sorts by recently updated and honours state" do
    stub_github_get("/repos/acme/docs-site/pulls", fixture: :pulls)

    pulls = @client.pull_requests("acme", "docs-site", state: "all")

    assert_equal [ 42, 41 ], pulls.map(&:number)
    assert_github_requested :get, "/repos/acme/docs-site/pulls",
                     query: { "state" => "all", "sort" => "updated", "direction" => "desc",
                              "per_page" => "100", "page" => "1" }
  end

  test "pull_requests maps author, labels, draft and head/base shas" do
    stub_github_get("/repos/acme/docs-site/pulls", fixture: :pulls)

    open_pull, draft_pull = @client.pull_requests("acme", "docs-site")

    assert_equal "Rewrite the getting-started guide", open_pull.title
    assert_equal "hubot", open_pull.author.login
    assert_equal %w[documentation needs-review], open_pull.labels.map(&:name)
    assert_equal "0075ca", open_pull.labels.first.color
    assert_equal "6dcb09b5b57875f334f61aebed695e2e4193db5e", open_pull.head_sha
    assert_equal "1c2d3e4f5061728394a5b6c7d8e9f0a1b2c3d4e5", open_pull.base_sha
    assert_equal "guide-rewrite", open_pull.head_ref
    assert_equal "main", open_pull.base_ref
    assert_not open_pull.draft?
    assert open_pull.open?

    assert draft_pull.draft?
    assert_empty draft_pull.labels
  end

  test "pull_request fetches one pull request with its counts" do
    stub_github_get("/repos/acme/docs-site/pulls/42", fixture: :pull)

    pull = @client.pull_request("acme", "docs-site", 42)

    assert_equal 42, pull.number
    assert_equal "PR_kwDOABCD12MAAAABc9Vk", pull.node_id
    assert_equal 5, pull.changed_files
    assert_equal 31, pull.additions
    assert_equal 9, pull.deletions
  end

  test "merged is derived from merged_at, which is all the list endpoint sends" do
    # GitHub's list response carries no `merged` key at all, only merged_at.
    # Reading `merged` alone rendered every merged pull request as "Closed".
    stub_github_get("/repos/acme/docs-site/pulls", fixture: :pulls_all)

    open_pull, draft_pull, merged_pull = @client.pull_requests("acme", "docs-site", state: "all")

    assert merged_pull.merged?
    assert_equal "closed", merged_pull.state
    assert_not open_pull.merged?
    assert_not draft_pull.merged?
  end

  test "merged still reads the show endpoint's own merged flag" do
    stub_github_get("/repos/acme/docs-site/pulls/42", body: github_fixture(:pull).merge("merged" => true))

    assert @client.pull_request("acme", "docs-site", 42).merged?
  end

  test "an open pull request is not merged" do
    stub_github_get("/repos/acme/docs-site/pulls/42", fixture: :pull)

    assert_not @client.pull_request("acme", "docs-site", 42).merged?
  end

  test "pull_request_files maps every status and keeps the patch verbatim" do
    stub_github_get("/repos/acme/docs-site/pulls/42/files", fixture: :pull_files)

    files = @client.pull_request_files("acme", "docs-site", 42)

    assert_equal %w[docs/guide.md docs/troubleshooting.md docs/legacy.md docs/install.md assets/diagram.png],
                 files.map(&:path)

    guide = files.first
    assert_equal "modified", guide.status
    assert guide.patch?
    assert_equal 4, guide.additions
    assert_equal 3, guide.deletions
    # The empty-string context line and the bare "+" blank added line must
    # survive untouched: Diff::Patch counts on them to keep line numbers aligned.
    assert_includes guide.patch, "\n\n+New paragraph.\n+\n Existing text."
    assert_includes guide.patch, "@@ -11,7 +13,6 @@ # Guide"
    # The hunk ends by deleting a whole paragraph, so the base side has a block
    # that no longer exists on the head side at all.
    assert_includes guide.patch, "\n Tail.\n-\n-Deprecated note."
  end

  test "pull_request_files marks files with no patch as uncommentable" do
    stub_github_get("/repos/acme/docs-site/pulls/42/files", fixture: :pull_files)

    files = @client.pull_request_files("acme", "docs-site", 42).index_by(&:path)

    renamed = files["docs/install.md"]
    assert renamed.renamed?
    assert_equal "docs/installation.md", renamed.previous_path
    assert_equal "docs/installation.md", renamed.base_path
    assert_nil renamed.patch
    assert_not renamed.patch?

    binary = files["assets/diagram.png"]
    assert_not binary.patch?
    assert_not binary.markdown?
  end

  test "markdown? recognises the Markdown extensions and nothing else" do
    stub_github_get("/repos/acme/docs-site/pulls/42/files", fixture: :pull_files)

    markdown = @client.pull_request_files("acme", "docs-site", 42).select(&:markdown?)

    assert_equal %w[docs/guide.md docs/troubleshooting.md docs/legacy.md docs/install.md],
                 markdown.map(&:path)
  end

  test "file_content requests raw bytes rather than the base64 envelope" do
    stub_github_raw_get("/repos/acme/docs-site/contents/docs/guide.md", fixture: "guide.md")

    content = @client.file_content("acme", "docs-site", "docs/guide.md",
                                   ref: "6dcb09b5b57875f334f61aebed695e2e4193db5e")

    assert_match(/\A# Guide\n/, content)
    assert_equal Encoding::UTF_8, content.encoding
    assert_github_requested :get, "/repos/acme/docs-site/contents/docs/guide.md",
                     headers: { "Accept" => "application/vnd.github.raw" },
                     query: { "ref" => "6dcb09b5b57875f334f61aebed695e2e4193db5e" }
  end

  test "file_content keeps path separators and escapes each segment" do
    stub_github_raw_get("/repos/acme/docs-site/contents/docs/a%20b/guide.md", body: "hi")

    assert_equal "hi", @client.file_content("acme", "docs-site", "docs/a b/guide.md", ref: "abc")
  end

  test "file_content returns nil when the file does not exist on that side" do
    stub_github_error(:get, "/repos/acme/docs-site/contents/docs/legacy.md",
                      status: 404, message: "Not Found")

    assert_nil @client.file_content("acme", "docs-site", "docs/legacy.md", ref: "deadbeef")
  end

  test "reviews maps state, author and the missing submitted_at of a pending review" do
    stub_github_get("/repos/acme/docs-site/pulls/42/reviews", fixture: :reviews)

    submitted, pending = @client.reviews("acme", "docs-site", 42)

    assert_equal "CHANGES_REQUESTED", submitted.state
    assert_equal "octocat", submitted.author.login
    assert_equal Time.utc(2026, 9, 17, 11, 0, 0), submitted.submitted_at
    assert_not submitted.pending?

    assert pending.pending?
    assert_nil pending.submitted_at
    assert_equal "PRR_kwDOABCD12MAAAABc9BB", pending.node_id
  end

  test "pending_review finds only the viewer's own draft" do
    stub_github_get("/repos/acme/docs-site/pulls/42/reviews", fixture: :reviews)

    review = @client.pending_review("acme", "docs-site", 42)

    assert_equal 80_002, review.id
    assert_equal "prism-dev", review.author.login
  end

  test "pending_review ignores a draft belonging to someone else" do
    other = Github::Client.new(users(:octocat))
    stub_github_get("/repos/acme/docs-site/pulls/42/reviews", fixture: :reviews)

    assert_nil other.pending_review("acme", "docs-site", 42)
  end

  test "reviews are never cached, because a submitted review must appear at once" do
    stub_github_get("/repos/acme/docs-site/pulls/42/reviews", fixture: :reviews)

    with_memory_cache do
      2.times { @client.reviews("acme", "docs-site", 42) }
    end

    assert_github_requested :get, "/repos/acme/docs-site/pulls/42/reviews", times: 2
  end

  # -------------------------------------------------------------- threads ---

  test "review_threads sends the ReviewThreads query with the right variables" do
    stub_github_graphql("ReviewThreads", fixture: :review_threads)

    @client.review_threads("acme", "docs-site", 42)

    variables = github_graphql_variables("ReviewThreads")
    assert_equal "acme", variables["owner"]
    assert_equal "docs-site", variables["name"]
    assert_equal 42, variables["number"]
    assert_nil variables["cursor"]
  end

  test "review_threads returns the pull request node id alongside the threads" do
    stub_github_graphql("ReviewThreads", fixture: :review_threads)

    result = @client.review_threads("acme", "docs-site", 42)

    assert_equal "PR_kwDOABCD12MAAAABc9Vk", result.pull_request_node_id
    assert_equal 5, result.threads.size
  end

  test "review_threads maps a right-side thread and its comments" do
    stub_github_graphql("ReviewThreads", fixture: :review_threads)

    thread = @client.review_threads("acme", "docs-site", 42).threads.first

    assert_equal "PRRT_kwDOABCD12MAAAAAAA1", thread.node_id
    assert_equal "docs/guide.md", thread.path
    assert_equal 3, thread.line
    assert_equal 3, thread.anchor_line
    assert thread.right_side?
    assert_not thread.resolved?
    assert_not thread.outdated?
    assert thread.viewer_can_resolve
    assert_nil thread.resolved_by

    root, reply = thread.comments
    assert_equal 900_001, root.id
    assert_equal "PRRC_kwDOABCD12MAAAABc9AA", root.node_id
    assert_equal "octocat", root.author.login
    assert_equal "<p>This paragraph repeats the heading above. Can we cut it?</p>", root.body_html
    assert root.root?
    assert_not root.viewer_can_update

    assert_equal "PRRC_kwDOABCD12MAAAABc9AA", reply.reply_to_node_id
    assert_not reply.root?
    assert reply.viewer_can_delete
  end

  test "review_threads drops empty reaction groups and translates to REST names" do
    stub_github_graphql("ReviewThreads", fixture: :review_threads)

    root = @client.review_threads("acme", "docs-site", 42).threads.first.comments.first

    assert_equal [ "+1", "heart" ], root.reaction_groups.map(&:content)
    thumbs = root.reaction_groups.first
    assert_equal 2, thumbs.count
    assert thumbs.viewer_has_reacted?
  end

  test "review_threads maps left-side, outdated, file-level and pending threads" do
    stub_github_graphql("ReviewThreads", fixture: :review_threads)

    threads = @client.review_threads("acme", "docs-site", 42).threads

    left = threads[1]
    assert_equal 14, left.line, "the LEFT thread sits on the deleted base line"
    assert left.left_side?
    assert left.resolved?
    assert_equal "prism-dev", left.resolved_by.login
    assert left.viewer_can_unresolve

    outdated = threads[2]
    assert outdated.outdated?
    assert_nil outdated.line
    assert_equal 42, outdated.original_line
    assert_predicate outdated.comments.first.diff_hunk, :present?

    file_level = threads[3]
    assert file_level.file_level?
    assert_nil file_level.anchor_line

    pending = threads[4]
    assert_equal 16, pending.start_line
    assert_equal 17, pending.line
    assert_equal "RIGHT", pending.start_diff_side
    assert pending.comments.first.pending?
  end

  test "review_threads follows pagination until hasNextPage is false" do
    page_one = github_fixture(:review_threads)
    page_one["data"]["repository"]["pullRequest"]["reviewThreads"]["pageInfo"] =
      { "hasNextPage" => true, "endCursor" => "CURSOR_1" }

    page_two = github_fixture(:review_threads)
    page_two["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"] = []

    responses = [ page_one, page_two ].map do |payload|
      { status: 200, body: payload.to_json, headers: GithubStubs::JSON_HEADERS }
    end
    stub_request(:post, "#{GithubStubs::API}/graphql").to_return(responses)

    result = @client.review_threads("acme", "docs-site", 42)

    assert_equal 5, result.threads.size
    assert_github_requested :post, "/graphql", times: 2
    assert_equal "CURSOR_1", github_graphql_requests.last[:variables]["cursor"]
  end

  test "review_threads raises NotFound when the pull request is missing" do
    stub_github_graphql("ReviewThreads", data: { "repository" => { "pullRequest" => nil } })

    assert_raises(Github::NotFound) { @client.review_threads("acme", "docs-site", 999) }
  end

  test "a thread with a null line is outdated even when GitHub did not set the flag" do
    # GitHub sets isOutdated when newer commits move the code, but a line-level
    # thread can come back with line null and isOutdated false. Either way there
    # is nothing to anchor to, so both must bucket as outdated.
    sneaky = Github::Types::ReviewThread.new(
      node_id: "T", path: "docs/guide.md", line: nil, original_line: 7,
      start_line: nil, original_start_line: nil, diff_side: "RIGHT",
      start_diff_side: nil, subject_type: "LINE", is_resolved: false,
      is_outdated: false, resolved_by: nil, viewer_can_resolve: true,
      viewer_can_unresolve: false, viewer_can_reply: true, comments: []
    )

    assert sneaky.outdated?
    assert_nil sneaky.anchor_line
  end

  test "a file-level thread has no line by design and is not outdated" do
    file_thread = Github::Types::ReviewThread.new(
      node_id: "T", path: "docs/guide.md", line: nil, original_line: nil,
      start_line: nil, original_start_line: nil, diff_side: "RIGHT",
      start_diff_side: nil, subject_type: "FILE", is_resolved: false,
      is_outdated: false, resolved_by: nil, viewer_can_resolve: true,
      viewer_can_unresolve: false, viewer_can_reply: true, comments: []
    )

    assert file_thread.file_level?
    assert_not file_thread.outdated?
    assert_nil file_thread.anchor_line
  end

  test "a thread with more than one page of comments is followed to the end" do
    # GraphQL pages comments like everything else. Asking for 100 covers almost
    # every thread, but a long argument would silently lose everything past the
    # hundredth comment — the worst failure this client could have, because the
    # user cannot tell that anything is missing.
    stub_github_graphql("ReviewThreads", fixture: :review_threads_paged)
    stub_request(:post, "#{GithubStubs::API}/graphql")
      .with { |request| graphql_operation_name(request.body) == "ThreadComments" }
      .to_return(
        { status: 200, body: github_fixture_raw("thread_comments_page_2.json"), headers: GithubStubs::JSON_HEADERS },
        { status: 200, body: github_fixture_raw("thread_comments_page_3.json"), headers: GithubStubs::JSON_HEADERS }
      )

    thread = @client.review_threads("acme", "docs-site", 42).threads.sole

    assert_equal [ 910_001, 910_002, 910_003, 910_004, 910_005 ], thread.comments.map(&:id),
                 "every page must arrive, in order"
    assert_equal 2, github_graphql_requests.count { |r| r[:operation] == "ThreadComments" },
                 "the loop must keep going until hasNextPage is false, not stop after one follow-up"
  end

  test "the follow-up comment query carries the thread id and the page cursor" do
    stub_github_graphql("ReviewThreads", fixture: :review_threads_paged)
    stub_github_graphql("ThreadComments", fixture: :thread_comments_page_3)

    @client.review_threads("acme", "docs-site", 42)

    variables = github_graphql_variables("ThreadComments")
    assert_equal "PRRT_paged_thread", variables["threadId"]
    assert_equal "COMMENTS_1", variables["cursor"]
  end

  test "a thread whose comments fit on one page asks for no follow-up" do
    stub_github_graphql("ReviewThreads", fixture: :review_threads)

    @client.review_threads("acme", "docs-site", 42)

    assert_empty github_graphql_requests.select { |r| r[:operation] == "ThreadComments" },
                 "hasNextPage is false for every fixture thread, so nothing should be fetched"
  end

  test "resolving a long thread keeps all of its comments" do
    thread = github_fixture(:review_threads_paged)
               .dig("data", "repository", "pullRequest", "reviewThreads", "nodes", 0)
    stub_github_graphql("ResolveThread", data: { "resolveReviewThread" => { "thread" => thread } })
    stub_github_graphql("ThreadComments", fixture: :thread_comments_page_3)

    result = @client.resolve_thread("PRRT_paged_thread")

    assert_equal [ 910_001, 910_002, 910_005 ], result.comments.map(&:id)
  end

  # --------------------------------------------------------- mentionables ---

  test "mentionables unions collaborators, org members and participants" do
    stub_github_get("/repos/acme/docs-site/collaborators", fixture: :collaborators)
    stub_github_get("/orgs/acme/members", fixture: :org_members)

    people = @client.mentionables("acme", "docs-site",
                                  participants: [ Github::Types::Author.new(login: "hubot", avatar_url: nil, html_url: nil) ])

    assert_equal %w[acme-admin hubot octocat prism-dev], people.map(&:login)
    assert_equal "The Octocat", people.find { |p| p.login == "octocat" }.name
  end

  test "mentionables falls back to assignees when collaborators is forbidden" do
    stub_github_error(:get, "/repos/acme/docs-site/collaborators", status: 403,
                      message: "Must have push access to view repository collaborators.")
    stub_github_get("/repos/acme/docs-site/assignees", fixture: :assignees)
    stub_github_get("/orgs/acme/members", fixture: :org_members)

    people = @client.mentionables("acme", "docs-site")

    assert_equal %w[acme-admin hubot octocat], people.map(&:login)
    assert_github_requested :get, "/repos/acme/docs-site/assignees"
  end

  test "mentionables tolerates a personal-account owner with no org members" do
    stub_github_get("/repos/prism-dev/scratchpad/collaborators", fixture: :collaborators)
    stub_github_error(:get, "/orgs/prism-dev/members", status: 404, message: "Not Found")

    people = @client.mentionables("prism-dev", "scratchpad")

    assert_equal %w[octocat prism-dev], people.map(&:login)
  end

  test "mentionables degrades to participants alone when GitHub refuses everything" do
    stub_github_error(:get, "/repos/acme/docs-site/collaborators", status: 403)
    stub_github_error(:get, "/repos/acme/docs-site/assignees", status: 403)
    stub_github_error(:get, "/orgs/acme/members", status: 403)

    people = @client.mentionables("acme", "docs-site", participants: [ "hubot" ])

    assert_equal %w[hubot], people.map(&:login)
  end

  test "mentionables deduplicates by login" do
    stub_github_get("/repos/acme/docs-site/collaborators", fixture: :collaborators)
    stub_github_get("/orgs/acme/members", fixture: :org_members)

    people = @client.mentionables("acme", "docs-site", participants: [ "octocat" ])

    assert_equal people.map(&:login).uniq, people.map(&:login)
  end

  # ----------------------------------------------------------- references ---

  test "references returns pull requests and issues from the one issues endpoint" do
    stub_github_get("/repos/acme/docs-site/issues", fixture: :issues)

    items = @client.references("acme", "docs-site")

    assert_equal [ 42, 41, 39, 37, 12 ], items.map(&:number)
    assert_equal %w[pull_request issue pull_request pull_request issue], items.map(&:kind)
    assert_github_not_requested :get, "/repos/acme/docs-site/pulls"
  end

  test "references asks for every state, most recently touched first" do
    stub_github_get("/repos/acme/docs-site/issues", fixture: :issues)

    @client.references("acme", "docs-site")

    assert_github_requested(:get, "/repos/acme/docs-site/issues",
                             query: hash_including({ "state" => "all", "sort" => "updated",
                                                     "direction" => "desc", "per_page" => "100" }))
  end

  # `state` alone says "closed" for both a merged pull request and an
  # abandoned one; only the nested pull_request.merged_at tells them apart.
  test "references reads merged and draft off the pull_request key" do
    stub_github_get("/repos/acme/docs-site/issues", fixture: :issues)

    by_number = @client.references("acme", "docs-site").index_by(&:number)

    assert by_number[39].merged?
    assert_equal "merged", by_number[39].status
    assert by_number[37].draft?
    assert_equal "draft", by_number[37].status
    assert_equal "open", by_number[42].status
    assert_equal "closed", by_number[12].status
    assert_not by_number[41].pull_request?
  end

  test "references are cached within their TTL" do
    stub_github_get("/repos/acme/docs-site/issues", fixture: :issues)

    with_memory_cache do |store|
      3.times { @client.references("acme", "docs-site") }

      assert_not_nil store.read([ "github", @user.id, :references, "acme", "docs-site" ])
    end

    assert_github_requested :get, "/repos/acme/docs-site/issues", times: 1
  end

  test "references answers empty when the repository has issues turned off" do
    stub_github_error(:get, "/repos/acme/docs-site/issues", status: 410, message: "Issues are disabled for this repo")

    assert_equal [], @client.references("acme", "docs-site")
  end

  test "references on a repository with issues disabled raises NotFound for the caller to swallow" do
    stub_github_error(:get, "/repos/acme/docs-site/issues", status: 404, message: "Not Found")

    assert_raises(Github::NotFound) { @client.references("acme", "docs-site") }
  end

  # ------------------------------------------------------------- markdown ---

  test "render_markdown posts gfm mode with the repository context" do
    stub_github_markdown(fixture: "markdown.html")

    html = @client.render_markdown("Nice catch, @octocat — see #12.", context: "acme/docs-site")

    assert_includes html, "user-mention"
    assert_equal({ "text" => "Nice catch, @octocat — see #12.",
                   "mode" => "gfm",
                   "context" => "acme/docs-site" },
                 github_request_body(:post, "/markdown"))
  end

  test "render_markdown short-circuits on blank input without calling GitHub" do
    assert_equal "", @client.render_markdown("   ", context: "acme/docs-site")

    assert_github_not_requested :post, "/markdown"
  end

  # --------------------------------------------------------------- writes ---

  test "create_thread posts the anchor against the pull request node id" do
    stub_github_graphql("AddThread", data: {
      "addPullRequestReviewThread" => {
        "thread" => github_fixture(:review_threads)
                      .dig("data", "repository", "pullRequest", "reviewThreads", "nodes", 0)
      }
    })

    thread = @client.create_thread(pull_request_node_id: "PR_1", anchor: line_anchor, body: "Nit.")

    assert_equal "PRRT_kwDOABCD12MAAAAAAA1", thread.node_id
    assert_equal({ "pullRequestId" => "PR_1", "body" => "Nit.", "path" => "docs/guide.md",
                   "line" => 3, "side" => "RIGHT", "subjectType" => "LINE" },
                 github_graphql_variables("AddThread")["input"])
  end

  test "create_thread carries a file-level anchor with no line at all" do
    stub_github_graphql("AddThread", data: {
      "addPullRequestReviewThread" => {
        "thread" => github_fixture(:review_threads)
                      .dig("data", "repository", "pullRequest", "reviewThreads", "nodes", 3)
      }
    })

    @client.create_thread(pull_request_node_id: "PR_1", anchor: file_anchor, body: "Outside the diff.")

    input = github_graphql_variables("AddThread")["input"]
    assert_equal "FILE", input["subjectType"]
    assert_not input.key?("line"), "a file-level anchor must not send a line"
    assert_not input.key?("side")
  end

  test "add_thread_to_review attaches the draft to the pending review, not the pull request" do
    stub_github_graphql("AddThread", data: {
      "addPullRequestReviewThread" => {
        "thread" => github_fixture(:review_threads)
                      .dig("data", "repository", "pullRequest", "reviewThreads", "nodes", 4)
      }
    })

    @client.add_thread_to_review(review_node_id: "PRR_1", anchor: line_anchor, body: "Draft.")

    input = github_graphql_variables("AddThread")["input"]
    assert_equal "PRR_1", input["pullRequestReviewId"]
    assert_not input.key?("pullRequestId"),
               "passing both ids would leave GitHub to guess which review we meant"
  end

  test "reply posts to the root comment's replies endpoint" do
    stub_github_post("/repos/acme/docs-site/pulls/42/comments/900001/replies", fixture: :reply)

    comment = @client.reply("acme", "docs-site", 42, 900_001, body: "Good catch, fixed in the next push.")

    assert_equal 990_001, comment.id
    assert_equal "prism-dev", comment.author.login
    assert_equal "SUBMITTED", comment.state
    assert comment.viewer_can_update
    assert_equal({ "body" => "Good catch, fixed in the next push." },
                 github_request_body(:post, "/repos/acme/docs-site/pulls/42/comments/900001/replies"))
  end

  test "reply_in_review drafts the reply inside the pending review" do
    stub_github_graphql("AddThreadReply", data: {
      "addPullRequestReviewThreadReply" => {
        "comment" => github_fixture(:review_threads)
                       .dig("data", "repository", "pullRequest", "reviewThreads", "nodes", 4,
                            "comments", "nodes", 0)
      }
    })

    comment = @client.reply_in_review(review_node_id: "PRR_1", thread_node_id: "PRRT_1", body: "Draft reply.")

    assert comment.pending?
    assert_equal({ "pullRequestReviewId" => "PRR_1",
                   "pullRequestReviewThreadId" => "PRRT_1",
                   "body" => "Draft reply." },
                 github_graphql_variables("AddThreadReply")["input"])
  end

  test "update_comment edits by node id" do
    stub_github_graphql("UpdateComment", data: {
      "updatePullRequestReviewComment" => {
        "pullRequestReviewComment" => github_fixture(:review_threads)
                                        .dig("data", "repository", "pullRequest", "reviewThreads",
                                             "nodes", 0, "comments", "nodes", 1)
      }
    })

    @client.update_comment("PRRC_1", body: "Edited.")

    assert_equal({ "pullRequestReviewCommentId" => "PRRC_1", "body" => "Edited." },
                 github_graphql_variables("UpdateComment")["input"])
  end

  test "delete_comment deletes by node id" do
    stub_github_graphql("DeleteComment", data: {
      "deletePullRequestReviewComment" => { "pullRequestReviewComment" => { "id" => "PRRC_1" } }
    })

    assert @client.delete_comment("PRRC_1")
    assert_equal({ "id" => "PRRC_1" }, github_graphql_variables("DeleteComment")["input"])
  end

  test "create_pending_review posts a review with no event" do
    stub_github_post("/repos/acme/docs-site/pulls/42/reviews", fixture: :pending_review)

    review = @client.create_pending_review("acme", "docs-site", 42,
                                           commit_id: "6dcb09b5b57875f334f61aebed695e2e4193db5e")

    assert review.pending?
    body = github_request_body(:post, "/repos/acme/docs-site/pulls/42/reviews")
    assert_equal "6dcb09b5b57875f334f61aebed695e2e4193db5e", body["commit_id"]
    assert_not body.key?("event"), "an event would submit the review immediately"
  end

  test "create_pending_review reuses the existing draft when GitHub says one already exists" do
    stub_github_error(:post, "/repos/acme/docs-site/pulls/42/reviews", status: 422,
                      message: "Validation Failed",
                      errors: [ { "resource" => "PullRequestReview",
                                  "code" => "custom",
                                  "message" => "User can only have one pending review per pull request" } ])
    stub_github_get("/repos/acme/docs-site/pulls/42/reviews", fixture: :reviews)

    review = @client.create_pending_review("acme", "docs-site", 42, commit_id: "abc")

    assert_equal 80_002, review.id
    assert review.pending?
  end

  test "create_pending_review re-raises when the 422 was not a duplicate draft" do
    stub_github_error(:post, "/repos/acme/docs-site/pulls/42/reviews", status: 422,
                      message: "Commit is not part of the pull request")
    stub_github_get("/repos/acme/docs-site/pulls/42/reviews", body: [])

    assert_raises(Github::Unprocessable) do
      @client.create_pending_review("acme", "docs-site", 42, commit_id: "stale")
    end
  end

  test "submit_review posts the event to the submit endpoint" do
    stub_github_post("/repos/acme/docs-site/pulls/42/reviews/80002/events",
                     fixture: :submitted_review, status: 200)

    review = @client.submit_review("acme", "docs-site", 42, 80_002, event: "APPROVE", body: "Looks good to me.")

    assert_equal "APPROVED", review.state
    assert_equal({ "event" => "APPROVE", "body" => "Looks good to me." },
                 github_request_body(:post, "/repos/acme/docs-site/pulls/42/reviews/80002/events"))
  end

  test "submit_review omits a blank body, which APPROVE allows" do
    stub_github_post("/repos/acme/docs-site/pulls/42/reviews/80002/events",
                     fixture: :submitted_review, status: 200)

    @client.submit_review("acme", "docs-site", 42, 80_002, event: "APPROVE")

    assert_equal({ "event" => "APPROVE" },
                 github_request_body(:post, "/repos/acme/docs-site/pulls/42/reviews/80002/events"))
  end

  test "delete_pending_review discards the draft" do
    stub_github_delete("/repos/acme/docs-site/pulls/42/reviews/80002")

    assert @client.delete_pending_review("acme", "docs-site", 42, 80_002)
    assert_github_requested :delete, "/repos/acme/docs-site/pulls/42/reviews/80002"
  end

  test "resolve_thread and unresolve_thread send the thread id" do
    node = github_fixture(:review_threads)
             .dig("data", "repository", "pullRequest", "reviewThreads", "nodes", 0)

    stub_github_graphql("ResolveThread", data: { "resolveReviewThread" => { "thread" => node } })
    stub_github_graphql("UnresolveThread", data: { "unresolveReviewThread" => { "thread" => node } })

    @client.resolve_thread("PRRT_1")
    @client.unresolve_thread("PRRT_2")

    assert_equal({ "threadId" => "PRRT_1" }, github_graphql_variables("ResolveThread")["input"])
    assert_equal({ "threadId" => "PRRT_2" }, github_graphql_variables("UnresolveThread")["input"])
  end

  test "add_reaction translates REST reaction names into the GraphQL enum" do
    comment = github_fixture(:review_threads)
                .dig("data", "repository", "pullRequest", "reviewThreads", "nodes", 0, "comments", "nodes", 0)
    stub_github_graphql("AddReaction", data: { "addReaction" => { "subject" => comment } })

    result = @client.add_reaction("PRRC_1", content: "+1")

    assert_equal({ "subjectId" => "PRRC_1", "content" => "THUMBS_UP" },
                 github_graphql_variables("AddReaction")["input"])
    assert_equal [ "+1", "heart" ], result.reaction_groups.map(&:content)
  end

  test "remove_reaction translates the enum too" do
    comment = github_fixture(:review_threads)
                .dig("data", "repository", "pullRequest", "reviewThreads", "nodes", 0, "comments", "nodes", 0)
    stub_github_graphql("RemoveReaction", data: { "removeReaction" => { "subject" => comment } })

    @client.remove_reaction("PRRC_1", content: "-1")

    assert_equal "THUMBS_DOWN", github_graphql_variables("RemoveReaction")["input"]["content"]
  end

  test "an unknown reaction is rejected before it reaches GitHub" do
    assert_raises(ArgumentError) { @client.add_reaction("PRRC_1", content: "shrug") }

    assert_github_not_requested :post, "/graphql"
  end

  test "the real Review::Anchor serializes into the mutation input" do
    # The other tests use a Struct stand-in so the client stays decoupled from
    # Workstream B. This one uses the genuine article, so a change to either
    # side of the anchor contract fails here rather than in production.
    stub_github_graphql("AddThread", data: {
      "addPullRequestReviewThread" => {
        "thread" => github_fixture(:review_threads)
                      .dig("data", "repository", "pullRequest", "reviewThreads", "nodes", 4)
      }
    })

    @client.create_thread(
      pull_request_node_id: "PR_1",
      anchor: Review::Anchor.multi_line(path: "docs/guide.md", start_line: 15, line: 18),
      body: "Both new lines read oddly."
    )

    # 15..18 is the paragraph that gained lines in the fixture: a contiguous
    # in-diff run, which is exactly when a multi-line anchor is the right shape.
    assert_equal({ "pullRequestId" => "PR_1", "body" => "Both new lines read oddly.",
                   "path" => "docs/guide.md", "line" => 18, "side" => "RIGHT",
                   "startLine" => 15, "startSide" => "RIGHT", "subjectType" => "LINE" },
                 github_graphql_variables("AddThread")["input"])
  end

  test "a real file-level anchor sends no line and no side" do
    stub_github_graphql("AddThread", data: {
      "addPullRequestReviewThread" => {
        "thread" => github_fixture(:review_threads)
                      .dig("data", "repository", "pullRequest", "reviewThreads", "nodes", 3)
      }
    })

    @client.create_thread(pull_request_node_id: "PR_1",
                          anchor: Review::Anchor.file("docs/guide.md"),
                          body: "Outside the diff.")

    assert_equal({ "pullRequestId" => "PR_1", "body" => "Outside the diff.",
                   "path" => "docs/guide.md", "subjectType" => "FILE" },
                 github_graphql_variables("AddThread")["input"])
  end

  # --------------------------------------------------------------- errors ---

  test "401 becomes Unauthorized" do
    stub_github_error(:get, "/user", status: 401, message: "Bad credentials")

    error = assert_raises(Github::Unauthorized) { @client.viewer }

    assert_equal "Bad credentials", error.message
    assert_equal 401, error.status
    # Deliberately not "expired": OAuth App tokens don't expire, they get
    # revoked or re-issued. See Github::Unauthorized.
    assert_match(/GitHub refused your sign-in/i, error.user_message)
    assert_no_match(/expired/i, error.user_message)
  end

  test "403 with a rate limit body becomes RateLimited and carries the reset time" do
    reset_at = 12.minutes.from_now.to_i
    stub_github_error(:get, "/user", status: 403,
                      message: "API rate limit exceeded for user ID 4242.",
                      headers: { "X-RateLimit-Limit" => "5000",
                                 "X-RateLimit-Remaining" => "0",
                                 "X-RateLimit-Reset" => reset_at.to_s })

    error = assert_raises(Github::RateLimited) { @client.viewer }

    assert_in_delta reset_at, error.reset_at.to_i, 1
    assert_in_delta 12.minutes.to_i, error.retry_in, 5
    assert_match(/rate limiting/i, error.user_message)
  end

  test "403 with retry-after prefers that over the reset header" do
    stub_github_error(:get, "/user", status: 403,
                      message: "You have exceeded a secondary rate limit",
                      headers: { "Retry-After" => "42" })

    error = assert_raises(Github::RateLimited) { @client.viewer }

    assert_equal 42, error.retry_after
    assert_equal 42, error.retry_in
  end

  test "a plain 403 becomes Forbidden, not RateLimited" do
    stub_github_error(:get, "/user", status: 403, message: "Resource not accessible")

    error = assert_raises(Github::Forbidden) { @client.viewer }

    assert_not_kind_of Github::RateLimited, error
  end

  test "404 becomes NotFound" do
    stub_github_error(:get, "/repos/acme/secret", status: 404, message: "Not Found")

    assert_raises(Github::NotFound) { @client.repo("acme", "secret") }
  end

  test "422 mentioning the diff becomes LineNotCommentable" do
    stub_github_graphql("AddThread", errors: [
      { "message" => "Pull request review thread line must be part of the diff",
        "type" => "UNPROCESSABLE" }
    ])

    error = assert_raises(Github::GraphQLError) do
      @client.create_thread(pull_request_node_id: "PR_1", anchor: line_anchor(line: 99), body: "Nope.")
    end

    assert_match(/must be part of the diff/, error.message)
  end

  test "a REST 422 mentioning the diff becomes LineNotCommentable" do
    stub_github_error(:post, "/repos/acme/docs-site/pulls/42/comments/900001/replies",
                      status: 422, message: "Validation Failed",
                      errors: [ { "message" => "Pull request review thread line must be part of the diff" } ])

    error = assert_raises(Github::LineNotCommentable) do
      @client.reply("acme", "docs-site", 42, 900_001, body: "Nope.")
    end

    assert_match(/file-level comment/i, error.user_message)
  end

  test "another 422 becomes Unprocessable and keeps GitHub's messages" do
    stub_github_error(:post, "/repos/acme/docs-site/pulls/42/comments/900001/replies",
                      status: 422, message: "Validation Failed",
                      errors: [ { "message" => "Body can't be blank" } ])

    error = assert_raises(Github::Unprocessable) { @client.reply("acme", "docs-site", 42, 900_001, body: "") }

    assert_equal "Validation Failed", error.message
    assert_includes error.errors, "Body can't be blank"
  end

  test "5xx becomes Unavailable" do
    stub_github_error(:get, "/user", status: 503, message: "Service unavailable")

    assert_raises(Github::Unavailable) { @client.viewer }
  end

  test "a connection failure becomes Unavailable" do
    stub_request(:get, "#{GithubStubs::API}/user").to_raise(Faraday::ConnectionFailed.new("boom"))

    assert_raises(Github::Unavailable) { @client.viewer }
  end

  test "GraphQL 200 with errors raises, because Octokit sees only the status" do
    stub_github_graphql("ReviewThreads", errors: [
      { "message" => "Something went wrong while executing your query." }
    ])

    error = assert_raises(Github::GraphQLError) { @client.review_threads("acme", "docs-site", 42) }

    assert_match(/Something went wrong/, error.message)
  end

  test "a GraphQL NOT_FOUND maps onto the same NotFound as REST" do
    stub_github_graphql("ResolveThread",
                        errors: [ { "message" => "Could not resolve to a node", "type" => "NOT_FOUND" } ])

    assert_raises(Github::NotFound) { @client.resolve_thread("PRRT_missing") }
  end

  test "every client error is a Github::Error, so one rescue catches them all" do
    [ Github::Unauthorized, Github::Forbidden, Github::NotFound, Github::RateLimited,
      Github::LineNotCommentable, Github::Unprocessable, Github::GraphQLError,
      Github::Unavailable ].each do |klass|
      assert_operator klass, :<, Github::Error
    end
  end

  # ---------------------------------------------------------------- cache ---

  test "reads are cached within their TTL" do
    stub_github_get("/repos/acme/docs-site/pulls/42", fixture: :pull)

    with_memory_cache do
      3.times { @client.pull_request("acme", "docs-site", 42) }
    end

    assert_github_requested :get, "/repos/acme/docs-site/pulls/42", times: 1
  end

  test "cache keys are namespaced by user, so two tokens never share an entry" do
    stub_github_get("/repos/acme/docs-site/pulls/42", fixture: :pull)
    other = Github::Client.new(users(:octocat))

    with_memory_cache do
      @client.pull_request("acme", "docs-site", 42)
      other.pull_request("acme", "docs-site", 42)
    end

    assert_github_requested :get, "/repos/acme/docs-site/pulls/42", times: 2
  end

  test "the cache key includes the user id" do
    stub_github_get("/user", fixture: :viewer)

    with_memory_cache do |store|
      @client.viewer

      assert_not_nil store.read([ "github", @user.id, :viewer ])
    end
  end

  test "pull_request_files caches by head sha when it is known" do
    stub_github_get("/repos/acme/docs-site/pulls/42/files", fixture: :pull_files)
    sha = "6dcb09b5b57875f334f61aebed695e2e4193db5e"

    with_memory_cache do |store|
      @client.pull_request_files("acme", "docs-site", 42, head_sha: sha)
      @client.pull_request_files("acme", "docs-site", 42, head_sha: sha)

      assert_not_nil store.read([ "github", @user.id, :files_by_sha, "acme", "docs-site", 42, sha ])
    end

    assert_github_requested :get, "/repos/acme/docs-site/pulls/42/files", times: 1
  end

  test "a different head sha is a different cache entry" do
    stub_github_get("/repos/acme/docs-site/pulls/42/files", fixture: :pull_files)

    with_memory_cache do
      @client.pull_request_files("acme", "docs-site", 42, head_sha: "aaa")
      @client.pull_request_files("acme", "docs-site", 42, head_sha: "bbb")
    end

    assert_github_requested :get, "/repos/acme/docs-site/pulls/42/files", times: 2
  end

  test "render_markdown caches by the digest of body and context" do
    stub_github_markdown(body: "<p>hi</p>")

    with_memory_cache do
      2.times { @client.render_markdown("hi", context: "acme/docs-site") }
      @client.render_markdown("hi", context: "other/repo")
    end

    assert_github_requested :post, "/markdown", times: 2
  end

  # ------------------------------------------------------------ transport ---

  test "requests are authenticated with the signed-in user's own token" do
    stub_github_get("/user", fixture: :viewer)

    @client.viewer

    assert_github_requested :get, "/user",
                     headers: { "Authorization" => "token gho_test_token_prism_dev" }
  end

  test "owner and repo names are escaped into the path" do
    stub_github_get("/repos/acme/docs%20site", fixture: :repo)

    @client.repo("acme", "docs site")

    assert_github_requested :get, "/repos/acme/docs%20site"
  end
end
