# frozen_string_literal: true

require "test_helper"

# ReviewCommentsController: create / reply / update / destroy, asserting the
# exact GitHub payloads (PLAN.md "Testing strategy") and the Turbo Stream
# targets the seam with workstream D promises.
class ReviewCommentsControllerTest < ActionDispatch::IntegrationTest
  OWNER = "acme"
  REPO = "docs-site"
  NUMBER = 42
  PATH = "docs/guide.md"
  HEAD_SHA = "6dcb09b5b57875f334f61aebed695e2e4193db5e"

  setup { @user = users(:prism_dev) }

  # ------------------------------------------------------------------ auth --

  test "signed out, create redirects to sign in" do
    post repo_pull_comments_path(owner: OWNER, repo: REPO, number: NUMBER),
         params: { path: PATH, line: 3, side: "RIGHT", body: "Hi", commit: "single", block_id: "b1" }

    assert_redirected_to sign_in_path
  end

  # --------------------------------------------------------------- create ---

  test "create posts a single-line comment immediately via GraphQL and streams the new thread" do
    sign_in_as(@user)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_graphql(:AddThread, data: { addPullRequestReviewThread: { thread: new_thread_data } })
    stub_review_threads([ new_thread_data ])
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", fixture: :reviews)

    post repo_pull_comments_path(owner: OWNER, repo: REPO, number: NUMBER),
         params: { path: PATH, line: 3, side: "RIGHT", subject_type: "line",
                   body: "Sentence case please.", commit: "single", block_id: "block_1" },
         as: :turbo_stream

    assert_response :success

    assert_github_graphql(:AddThread) do |variables|
      input = variables["input"]
      input["pullRequestId"] == "PR_kwDOABCD12MAAAABc9Vk" &&
        input["path"] == PATH && input["line"] == 3 && input["side"] == "RIGHT" &&
        input["body"] == "Sentence case please." && input["subjectType"] == "LINE" &&
        !input.key?("pullRequestReviewId")
    end

    assert_match(/turbo-stream action="append" target="threads_block_1"/, response.body)
    assert_match(/turbo-stream action="update" target="composer_block_1"/, response.body)
    assert_match(/turbo-stream action="replace" target="pending_tray"/, response.body)
    assert_match("Sentence case please.", response.body)
  end

  test "create with commit=review starts a pending review then adds the draft thread to it" do
    sign_in_as(@user)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", body: [].to_json)
    stub_github_post("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", fixture: :pending_review)
    draft = new_thread_data(state: "PENDING")
    stub_github_graphql(:AddThread, data: { addPullRequestReviewThread: { thread: draft } })
    stub_review_threads([ draft ])

    post repo_pull_comments_path(owner: OWNER, repo: REPO, number: NUMBER),
         params: { path: PATH, line: 3, side: "RIGHT", subject_type: "line",
                   body: "Draft note.", commit: "review", block_id: "block_1" },
         as: :turbo_stream

    assert_response :success
    assert_github_requested :post, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews"
    assert_equal HEAD_SHA, github_request_body(:post, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews")["commit_id"]
    assert_github_graphql(:AddThread) { |variables| variables["input"]["pullRequestReviewId"] == "PRR_kwDOABCD12MAAAABc9BB" }
  end

  test "create when a pending review already exists (422) reuses it instead of erroring" do
    sign_in_as(@user)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", fixture: :reviews)
    draft = new_thread_data(state: "PENDING")
    stub_github_graphql(:AddThread, data: { addPullRequestReviewThread: { thread: draft } })
    stub_review_threads([ draft ])

    post repo_pull_comments_path(owner: OWNER, repo: REPO, number: NUMBER),
         params: { path: PATH, line: 3, side: "RIGHT", subject_type: "line",
                   body: "Draft note.", commit: "review", block_id: "block_1" },
         as: :turbo_stream

    assert_response :success
    # reviews.json already has a PENDING review for prism-dev — no POST .../reviews needed.
    assert_github_not_requested :post, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews"
    assert_github_graphql(:AddThread) { |variables| variables["input"]["pullRequestReviewId"] == "PRR_kwDOABCD12MAAAABc9BB" }
    # Review::CommentWriter#ensure_pending_review already resolved the review for
    # this request; ReviewCommentsController#current_pending_review (rendering
    # the tray) must reuse it rather than paying for a second GET .../reviews.
    assert_github_requested :get, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", times: 1
  end

  test "a file-level comment (outside the diff) is built server-side with the quote and permalink" do
    sign_in_as(@user)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    draft = new_thread_data(subject_type: "FILE", line: nil)
    stub_github_graphql(:AddThread, data: { addPullRequestReviewThread: { thread: draft } })
    stub_review_threads([ draft ])
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", fixture: :reviews)

    post repo_pull_comments_path(owner: OWNER, repo: REPO, number: NUMBER),
         params: { path: PATH, subject_type: "file", body: "Cut this.", commit: "single",
                   block_id: "block_9", block_text: "Some heading text", block_start_line: 40, block_end_line: 41 },
         as: :turbo_stream

    assert_response :success
    assert_github_graphql(:AddThread) do |variables|
      input = variables["input"]
      body = input["body"]
      input["subjectType"] == "FILE" && !input.key?("line") &&
        body.include?("> Some heading text") &&
        body.include?("https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{PATH}#L40-L41") &&
        body.end_with?("Cut this.")
    end
  end

  # L1 (independent review, 2026-09-19): a file-level thread must land where
  # a full page load would put it (Review::BlockMapper buckets subject_type
  # FILE into #file_threads, never under a block) — otherwise it jumps to
  # the top the next time the page loads.
  test "a file-level comment streams into #file_threads, not the block's own container" do
    sign_in_as(@user)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    draft = new_thread_data(subject_type: "FILE", line: nil)
    stub_github_graphql(:AddThread, data: { addPullRequestReviewThread: { thread: draft } })
    stub_review_threads([ draft ])
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", fixture: :reviews)

    post repo_pull_comments_path(owner: OWNER, repo: REPO, number: NUMBER),
         params: { path: PATH, subject_type: "file", body: "Cut this.", commit: "single",
                   block_id: "block_9", block_text: "Some heading text", block_start_line: 40, block_end_line: 41 },
         as: :turbo_stream

    assert_response :success
    assert_match(/turbo-stream action="prepend" target="file_threads"/, response.body)
    assert_no_match(/turbo-stream action="append" target="threads_block_9"/, response.body)
  end

  # Performance fix requested 2026-09-19 ("saving a comment feels slow"): the
  # heaviest call in a create request was re-fetching every thread on the
  # pull request (reviewThreads, up to 50 threads x 100 comments) just to
  # find the one thread this request already had from the mutation's own
  # response. This also retired the M7 read-after-write race the independent
  # review had flagged earlier the same day — there is no second fetch left
  # to lag behind the mutation, so nothing to fall back from.
  test "create does not refetch review_threads and streams the mutation's own thread verbatim" do
    sign_in_as(@user)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_graphql(:AddThread,
                         data: { addPullRequestReviewThread: { thread: new_thread_data(node_id: "PRRT_verbatim", body: "Exactly this.") } })

    post repo_pull_comments_path(owner: OWNER, repo: REPO, number: NUMBER),
         params: { path: PATH, line: 3, side: "RIGHT", subject_type: "line",
                   body: "Exactly this.", commit: "single", block_id: "block_1" },
         as: :turbo_stream

    assert_response :success
    refute github_graphql_requests.any? { |r| r[:operation] == "ReviewThreads" },
           "create must not query reviewThreads any more"
    # No stub is registered for GET .../reviews at all — if create's success
    # path called it, WebMock would raise before this assertion even runs.
    assert_github_not_requested :get, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews"
    assert_match(/turbo-stream action="append" target="threads_block_1"/, response.body)
    assert_match('id="thread_PRRT_verbatim"', response.body)
    assert_match("<p>Exactly this.</p>", response.body)
    assert_match(/turbo-stream action="update" target="composer_block_1"/, response.body)
  end

  test "create in review mode increments the pending count from the composer's hidden field, with only the one necessary GET" do
    sign_in_as(@user)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", fixture: :reviews) # already has a PENDING review
    draft = new_thread_data(node_id: "PRRT_draft", state: "PENDING")
    stub_github_graphql(:AddThread, data: { addPullRequestReviewThread: { thread: draft } })

    post repo_pull_comments_path(owner: OWNER, repo: REPO, number: NUMBER),
         params: { path: PATH, line: 3, side: "RIGHT", subject_type: "line",
                   body: "Add to the review.", commit: "review", block_id: "block_1", pending_count: "1" },
         as: :turbo_stream

    assert_response :success
    refute github_graphql_requests.any? { |r| r[:operation] == "ReviewThreads" }
    # Exactly once — from ensure_pending_review finding the existing draft,
    # not once for that *and* a second time to render the tray.
    assert_github_requested :get, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", times: 1
    assert_match("2 pending comments", response.body)
  end

  test "a single comment after a review was already started still shows the tray, from hidden fields alone" do
    sign_in_as(@user)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_graphql(:AddThread, data: { addPullRequestReviewThread: { thread: new_thread_data(node_id: "PRRT_single") } })

    post repo_pull_comments_path(owner: OWNER, repo: REPO, number: NUMBER),
         params: { path: PATH, line: 3, side: "RIGHT", subject_type: "line",
                   body: "Just a note.", commit: "single", block_id: "block_1",
                   pending_review_node_id: "PRR_kwDOABCD12MAAAABc9BB", pending_review_id: "80002",
                   pending_count: "3" },
         as: :turbo_stream

    assert_response :success
    assert_github_not_requested :get, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews"
    # Unchanged — a single comment does not join the pending review — and
    # the tray still points at the review the client already knew about.
    assert_match("3 pending comments", response.body)
    assert_match(%r{action="/acme/docs-site/pulls/42/reviews/80002/submit"}, response.body)
  end

  # Test gap flagged by the independent review (2026-09-19): the multi-line
  # branch of build_anchor had no coverage through a controller. The shared
  # docs/guide.md fixture's second hunk (@@ -11,5 +13,6 @@) makes head lines
  # 13-18 a contiguous in-diff run, and lines 15-18 ("Prose here." / "New
  # line." / "Another." / "Tail.") are one paragraph block, so
  # Review::AnchorResolver emits a genuine multi-line anchor
  # (start_line: 15, line: 18) for it — confirmed by running the real
  # Markdown::Document/Diff::Patch/Review::AnchorResolver pipeline over the
  # fixture as it stands today.
  test "a multi-line anchor posts startLine/startSide alongside line/side" do
    sign_in_as(@user)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", fixture: :reviews)
    draft = new_thread_data(line: 18)
    stub_github_graphql(:AddThread, data: { addPullRequestReviewThread: { thread: draft } })
    stub_review_threads([ draft ])

    post repo_pull_comments_path(owner: OWNER, repo: REPO, number: NUMBER),
         params: { path: PATH, start_line: 15, line: 18, side: "RIGHT", start_side: "RIGHT",
                   subject_type: "line", body: "This whole paragraph could be one sentence.",
                   commit: "single", block_id: "block_multi" },
         as: :turbo_stream

    assert_response :success
    assert_github_graphql(:AddThread) do |variables|
      input = variables["input"]
      input["startLine"] == 15 && input["startSide"] == "RIGHT" &&
        input["line"] == 18 && input["side"] == "RIGHT"
    end
  end

  test "a 422 line-not-commentable error re-renders the composer with the message and the reviewer's text" do
    sign_in_as(@user)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", fixture: :reviews)
    stub_github_graphql(:AddThread, errors: [
      { "message" => "Pull request review thread line must be part of the diff" }
    ])

    post repo_pull_comments_path(owner: OWNER, repo: REPO, number: NUMBER),
         params: { path: PATH, line: 999, side: "RIGHT", subject_type: "line",
                   body: "My careful comment", commit: "single", block_id: "block_1" },
         as: :turbo_stream

    assert_response :unprocessable_content
    assert_match(/turbo-stream action="update" target="composer_block_1"/, response.body)
    assert_match("My careful comment", response.body)
    assert_match("GitHub only accepts comments on lines that appear in this pull request", response.body)
  end

  # ---------------------------------------------------------------- reply ---

  # Performance fix requested 2026-09-19 ("saving a comment feels slow"):
  # reply now renders straight from its own REST/GraphQL payload — appended
  # into the thread's own comments container — instead of refetching
  # reviewThreads to rebuild the whole thread. No stub is registered for
  # either GET .../reviews or the ReviewThreads GraphQL query.
  test "reply posts immediately over REST and appends the comment with no refetch" do
    sign_in_as(@user)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_post("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/comments/900001/replies", fixture: :reply)

    post repo_pull_comment_replies_path(owner: OWNER, repo: REPO, number: NUMBER, id: 900001),
         params: { thread_id: "PRRT_kwDOABCD12MAAAAAAA1", body: "Fixed in the next push.", review: "0" },
         as: :turbo_stream

    assert_response :success
    assert_github_requested :post, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/comments/900001/replies"
    refute github_graphql_requests.any? { |r| r[:operation] == "ReviewThreads" }
    assert_github_not_requested :get, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews"
    assert_match(/turbo-stream action="append" target="thread_comments_PRRT_kwDOABCD12MAAAAAAA1"/, response.body)
    # reply.json's own fixed body — the response is a stubbed fixture, not an
    # echo of what this test posted.
    assert_match("Good catch, fixed in the next push.", response.body)
  end

  test "reply with review=1 adds a draft reply to the pending review over GraphQL, with only the one necessary GET" do
    sign_in_as(@user)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", fixture: :reviews) # ensure_pending_review's own lookup
    stub_github_graphql(:AddThreadReply, data: { addPullRequestReviewThreadReply: { comment: comment_data(node_id: "PRRC_new") } })

    post repo_pull_comment_replies_path(owner: OWNER, repo: REPO, number: NUMBER, id: 900001),
         params: { thread_id: "PRRT_kwDOABCD12MAAAAAAA1", body: "Draft reply.", review: "1",
                   pending_count: "1" },
         as: :turbo_stream

    assert_response :success
    assert_github_graphql(:AddThreadReply) do |variables|
      variables["input"]["pullRequestReviewId"] == "PRR_kwDOABCD12MAAAABc9BB" &&
        variables["input"]["pullRequestReviewThreadId"] == "PRRT_kwDOABCD12MAAAAAAA1" &&
        variables["input"]["body"] == "Draft reply."
    end
    refute github_graphql_requests.any? { |r| r[:operation] == "ReviewThreads" }
    assert_github_requested :get, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", times: 1
    assert_match("2 pending comments", response.body)
  end

  # ---------------------------------------------------------------- update --

  test "update edits a comment's body over GraphQL by node id and replaces the comment card" do
    sign_in_as(@user)
    stub_github_graphql(:UpdateComment,
                         data: { updatePullRequestReviewComment: { pullRequestReviewComment: comment_data(node_id: "PRRC_kwDOABCD12MAAAABc9AB", body: "Edited body.") } })

    patch repo_pull_comment_path(owner: OWNER, repo: REPO, number: NUMBER, id: "PRRC_kwDOABCD12MAAAABc9AB"),
          params: { body: "Edited body.", thread_id: "PRRT_kwDOABCD12MAAAAAAA1" },
          as: :turbo_stream

    assert_response :success
    assert_github_graphql(:UpdateComment) do |variables|
      variables["input"]["pullRequestReviewCommentId"] == "PRRC_kwDOABCD12MAAAABc9AB" &&
        variables["input"]["body"] == "Edited body."
    end
    assert_match(/turbo-stream action="replace" target="comment_PRRC_kwDOABCD12MAAAABc9AB"/, response.body)
    assert_match("Edited body.", response.body)
  end

  # Regression for a bug ws-f-e2e caught in a real browser (2026-09-19):
  # _edit_form.html.erb had no hidden thread_id field, unlike _reply_form's
  # `f.hidden_field :thread_id`. This test's params carry thread_id
  # explicitly and so cannot catch that on its own — what matters is that the
  # *rendered edit form this response ships* also carries it, so the next
  # real Delete submit (which reads thread_id from that form, not from this
  # test) still has one.
  test "the re-rendered edit pane still carries the thread's node id as a hidden field" do
    sign_in_as(@user)
    stub_github_graphql(:UpdateComment,
                         data: { updatePullRequestReviewComment: { pullRequestReviewComment: comment_data(node_id: "PRRC_kwDOABCD12MAAAABc9AB", body: "Edited body.") } })

    patch repo_pull_comment_path(owner: OWNER, repo: REPO, number: NUMBER, id: "PRRC_kwDOABCD12MAAAABc9AB"),
          params: { body: "Edited body.", thread_id: "PRRT_kwDOABCD12MAAAAAAA1" },
          as: :turbo_stream

    assert_response :success
    assert_select "form[data-testid=comment-edit-form] input[type=hidden][name=thread_id][value='PRRT_kwDOABCD12MAAAAAAA1']"
  end

  # The full round trip: edit a comment, then delete it using only the
  # thread_id the edit response's own form handed back — not a value this
  # test supplies itself. Before the fix this hidden field was missing
  # entirely, so a real browser would submit thread_id="" on the delete and
  # ReviewCommentsController#render_after_delete would skip touching the
  # thread altogether (thread_id.present? is false), leaving a stale card on
  # the page even though GitHub had genuinely deleted the comment.
  test "editing a comment and then deleting it still finds and removes the thread" do
    sign_in_as(@user)
    stub_github_graphql(:UpdateComment,
                         data: { updatePullRequestReviewComment: { pullRequestReviewComment: comment_data(node_id: "PRRC_kwDOABCD12MAAAABc9AB", body: "Edited body.") } })

    patch repo_pull_comment_path(owner: OWNER, repo: REPO, number: NUMBER, id: "PRRC_kwDOABCD12MAAAABc9AB"),
          params: { body: "Edited body.", thread_id: "PRRT_kwDOABCD12MAAAAAAA1" },
          as: :turbo_stream
    assert_response :success

    # The comment card also carries a `thread_id` hidden field in every
    # reaction form and the Delete button — parsed rather than pattern
    # matched, so this reads specifically the edit form's own field and
    # cannot accidentally pass by matching one of those instead.
    edit_form = Nokogiri::HTML5.fragment(response.body).at_css('form[data-testid="comment-edit-form"]')
    thread_id_from_edit_form = edit_form.at_css('input[name="thread_id"]')&.[]("value")
    assert_equal "PRRT_kwDOABCD12MAAAAAAA1", thread_id_from_edit_form,
                 "the edit form's own hidden field, not a value this test invented"

    stub_github_graphql(:DeleteComment, data: { deletePullRequestReviewComment: { pullRequestReviewComment: { id: "PRRC_kwDOABCD12MAAAABc9AB" } } })
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", fixture: :reviews)
    stub_review_threads([]) # the thread had only this one comment; GitHub removed it entirely

    delete repo_pull_comment_path(owner: OWNER, repo: REPO, number: NUMBER, id: "PRRC_kwDOABCD12MAAAABc9AB"),
           params: { thread_id: thread_id_from_edit_form },
           as: :turbo_stream

    assert_response :success
    assert_match(/turbo-stream action="remove" target="thread_PRRT_kwDOABCD12MAAAAAAA1"/, response.body)
  end

  # --------------------------------------------------------------- destroy --

  test "destroy deletes a comment over GraphQL and removes the thread when it was the last comment" do
    sign_in_as(@user)
    stub_github_graphql(:DeleteComment, data: { deletePullRequestReviewComment: { pullRequestReviewComment: { id: "PRRC_kwDOABCD12MAAAABc9AC" } } })
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", fixture: :reviews)
    # The thread this comment belonged to no longer comes back at all.
    stub_review_threads([])

    delete repo_pull_comment_path(owner: OWNER, repo: REPO, number: NUMBER, id: "PRRC_kwDOABCD12MAAAABc9AC"),
           params: { thread_id: "PRRT_kwDOABCD12MAAAAAAA2" },
           as: :turbo_stream

    assert_response :success
    assert_github_graphql(:DeleteComment) { |variables| variables["input"]["id"] == "PRRC_kwDOABCD12MAAAABc9AC" }
    assert_match(/turbo-stream action="remove" target="thread_PRRT_kwDOABCD12MAAAAAAA2"/, response.body)
  end

  # ------------------------------------------------------- repo-level errors --

  test "create against a pull request GitHub 404s replaces the composer instead of a 500" do
    sign_in_as(@user)
    stub_github_error(:get, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", status: 404, message: "Not Found")

    post repo_pull_comments_path(owner: OWNER, repo: REPO, number: NUMBER),
         params: { path: PATH, line: 3, side: "RIGHT", subject_type: "line",
                   body: "Hi", commit: "single", block_id: "block_1" },
         as: :turbo_stream

    assert_response :not_found
    assert_match(/turbo-stream action="update" target="composer_block_1"/, response.body)
    assert_match(/not found|access to it/i, response.body)
  end

  test "create against a repository GitHub forbids replaces the composer, not the whole page" do
    sign_in_as(@user)
    stub_github_error(:get, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", status: 403, message: "Resource not accessible")

    post repo_pull_comments_path(owner: OWNER, repo: REPO, number: NUMBER),
         params: { path: PATH, line: 3, side: "RIGHT", subject_type: "line",
                   body: "Hi", commit: "single", block_id: "block_1" },
         as: :turbo_stream

    assert_response :forbidden
    assert_match(/turbo-stream action="update" target="composer_block_1"/, response.body)
  end

  test "create against a pull request GitHub 404s renders the full not-found page for a plain request" do
    sign_in_as(@user)
    stub_github_error(:get, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", status: 404, message: "Not Found")

    post repo_pull_comments_path(owner: OWNER, repo: REPO, number: NUMBER),
         params: { path: PATH, line: 3, side: "RIGHT", subject_type: "line", body: "Hi", commit: "single", block_id: "block_1" }

    assert_response :not_found
    assert_select "[data-testid=empty-state]"
  end

  test "reply against a pull request GitHub 404s replaces the thread instead of a 500" do
    sign_in_as(@user)
    stub_github_error(:get, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", status: 404, message: "Not Found")

    post repo_pull_comment_replies_path(owner: OWNER, repo: REPO, number: NUMBER, id: 900001),
         params: { thread_id: "PRRT_kwDOABCD12MAAAAAAA1", body: "Hi", review: "0" },
         as: :turbo_stream

    assert_response :not_found
    assert_match(/turbo-stream action="replace" target="thread_PRRT_kwDOABCD12MAAAAAAA1"/, response.body)
  end

  test "update against a comment GitHub can no longer find replaces the comment card" do
    sign_in_as(@user)
    stub_github_graphql(:UpdateComment, errors: [ { "message" => "Could not resolve to a node.", "type" => "NOT_FOUND" } ])

    patch repo_pull_comment_path(owner: OWNER, repo: REPO, number: NUMBER, id: "PRRC_gone"),
          params: { body: "Edited.", thread_id: "PRRT_kwDOABCD12MAAAAAAA1" },
          as: :turbo_stream

    assert_response :not_found
    assert_match(/turbo-stream action="replace" target="comment_PRRC_gone"/, response.body)
  end

  test "destroy against a comment GitHub can no longer find replaces the thread, not the whole page" do
    sign_in_as(@user)
    stub_github_graphql(:DeleteComment, errors: [ { "message" => "Could not resolve to a node.", "type" => "NOT_FOUND" } ])

    delete repo_pull_comment_path(owner: OWNER, repo: REPO, number: NUMBER, id: "PRRC_gone"),
           params: { thread_id: "PRRT_kwDOABCD12MAAAAAAA1" },
           as: :turbo_stream

    assert_response :not_found
    assert_match(/turbo-stream action="replace" target="thread_PRRT_kwDOABCD12MAAAAAAA1"/, response.body)
  end

  # --------------------------------------------------------- bad anchor params --

  test "a bad side param on create re-renders the composer with a message instead of a 500" do
    sign_in_as(@user)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", fixture: :reviews)

    post repo_pull_comments_path(owner: OWNER, repo: REPO, number: NUMBER),
         params: { path: PATH, line: 3, side: "sideways", subject_type: "line",
                   body: "Hi", commit: "single", block_id: "block_1" },
         as: :turbo_stream

    assert_response :unprocessable_content
    assert_match(/turbo-stream action="update" target="composer_block_1"/, response.body)
    assert_match("Hi", response.body) # the reviewer's text survives the error
  end

  test "a reversed multi-line range on create re-renders the composer rather than raising" do
    sign_in_as(@user)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", fixture: :reviews)

    post repo_pull_comments_path(owner: OWNER, repo: REPO, number: NUMBER),
         params: { path: PATH, line: 3, start_line: 10, side: "RIGHT", subject_type: "line",
                   body: "Hi", commit: "single", block_id: "block_1" },
         as: :turbo_stream

    assert_response :unprocessable_content
    assert_match(/turbo-stream action="update" target="composer_block_1"/, response.body)
  end

  private

  def new_thread_data(node_id: "PRRT_new1", subject_type: "LINE", line: 3, state: "SUBMITTED",
                       body: "Sentence case please.")
    {
      id: node_id, path: PATH, line: line, originalLine: line, startLine: nil, originalStartLine: nil,
      diffSide: "RIGHT", startDiffSide: nil, subjectType: subject_type,
      isResolved: false, isOutdated: false, viewerCanResolve: true, viewerCanUnresolve: false,
      viewerCanReply: true, resolvedBy: nil,
      comments: { pageInfo: { hasNextPage: false, endCursor: nil },
                  nodes: [ comment_data(node_id: "PRRC_new1", state: state, body: body) ] }
    }
  end

  def comment_data(node_id:, state: "SUBMITTED", body: "Sentence case please.")
    {
      id: node_id, databaseId: 123_456, body: body, bodyHTML: "<p>#{body}</p>", state: state,
      createdAt: "2026-09-19T10:00:00Z", url: "https://github.com/#{OWNER}/#{REPO}/pull/#{NUMBER}#discussion_r123456",
      diffHunk: "", outdated: false, viewerCanUpdate: true, viewerCanDelete: true, viewerCanReact: true,
      author: { login: "prism-dev", avatarUrl: "https://avatars.githubusercontent.com/u/4242?v=4",
                url: "https://github.com/prism-dev" },
      replyTo: nil, reactionGroups: []
    }
  end

  def stub_review_threads(nodes)
    stub_github_graphql(:ReviewThreads, data: {
      repository: { pullRequest: {
        id: "PR_kwDOABCD12MAAAABc9Vk",
        reviewThreads: { pageInfo: { hasNextPage: false, endCursor: nil }, nodes: nodes }
      } }
    })
  end
end
