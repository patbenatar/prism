# frozen_string_literal: true

require "test_helper"

# ReviewThreadsController: resolve / unresolve, both GraphQL-only.
class ReviewThreadsControllerTest < ActionDispatch::IntegrationTest
  OWNER = "acme"
  REPO = "docs-site"
  NUMBER = 42
  THREAD_ID = "PRRT_kwDOABCD12MAAAAAAA1"

  setup { @user = users(:prism_dev) }

  test "signed out, resolve redirects to sign in" do
    post repo_pull_thread_resolve_path(owner: OWNER, repo: REPO, number: NUMBER, id: THREAD_ID)

    assert_redirected_to sign_in_path
  end

  test "resolve calls resolveReviewThread and replaces the thread card" do
    sign_in_as(@user)
    stub_github_graphql(:ResolveThread, data: { resolveReviewThread: { thread: resolved_thread_data } })
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_review_threads([ resolved_thread_data ])
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", body: [].to_json)

    post repo_pull_thread_resolve_path(owner: OWNER, repo: REPO, number: NUMBER, id: THREAD_ID), as: :turbo_stream

    assert_response :success
    assert_github_graphql(:ResolveThread) { |variables| variables["input"]["threadId"] == THREAD_ID }
    assert_match(/turbo-stream action="replace" target="thread_#{THREAD_ID}"/, response.body)
    assert_match("Resolved", response.body)
  end

  test "unresolve calls unresolveReviewThread" do
    sign_in_as(@user)
    unresolved = resolved_thread_data.merge(isResolved: false, viewerCanResolve: true, viewerCanUnresolve: false)
    stub_github_graphql(:UnresolveThread, data: { unresolveReviewThread: { thread: unresolved } })
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_review_threads([ unresolved ])
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", body: [].to_json)

    post repo_pull_thread_unresolve_path(owner: OWNER, repo: REPO, number: NUMBER, id: THREAD_ID), as: :turbo_stream

    assert_response :success
    assert_github_graphql(:UnresolveThread) { |variables| variables["input"]["threadId"] == THREAD_ID }
  end

  test "resolving a thread GitHub can no longer find replaces that thread, not the whole page" do
    sign_in_as(@user)
    stub_github_graphql(:ResolveThread, errors: [ { "message" => "Could not resolve to a node.", "type" => "NOT_FOUND" } ])

    post repo_pull_thread_resolve_path(owner: OWNER, repo: REPO, number: NUMBER, id: THREAD_ID), as: :turbo_stream

    assert_response :not_found
    assert_match(/turbo-stream action="replace" target="thread_#{THREAD_ID}"/, response.body)
  end

  test "resolving a thread on a repository GitHub forbids replaces that thread with the reason" do
    sign_in_as(@user)
    stub_github_graphql(:ResolveThread, errors: [ { "message" => "Resource not accessible", "type" => "FORBIDDEN" } ])

    post repo_pull_thread_resolve_path(owner: OWNER, repo: REPO, number: NUMBER, id: THREAD_ID), as: :turbo_stream

    assert_response :forbidden
    assert_match(/turbo-stream action="replace" target="thread_#{THREAD_ID}"/, response.body)
  end

  test "resolving a thread GitHub can no longer find renders the full not-found page for a plain request" do
    sign_in_as(@user)
    stub_github_graphql(:ResolveThread, errors: [ { "message" => "Could not resolve to a node.", "type" => "NOT_FOUND" } ])

    post repo_pull_thread_resolve_path(owner: OWNER, repo: REPO, number: NUMBER, id: THREAD_ID)

    assert_response :not_found
    assert_select "[data-testid=empty-state]"
  end

  private

  def resolved_thread_data
    {
      id: THREAD_ID, path: "docs/guide.md", line: 3, originalLine: 3, startLine: nil, originalStartLine: nil,
      diffSide: "RIGHT", startDiffSide: nil, subjectType: "LINE",
      isResolved: true, isOutdated: false, viewerCanResolve: false, viewerCanUnresolve: true,
      viewerCanReply: true, resolvedBy: { login: "prism-dev" },
      comments: { pageInfo: { hasNextPage: false, endCursor: nil }, nodes: [
        { id: "PRRC_1", databaseId: 900001, body: "Hi", bodyHTML: "<p>Hi</p>", state: "SUBMITTED",
          createdAt: "2026-09-17T11:00:00Z", url: "https://github.com/x", diffHunk: "", outdated: false,
          viewerCanUpdate: false, viewerCanDelete: false, viewerCanReact: true,
          author: { login: "octocat", avatarUrl: "https://x", url: "https://github.com/octocat" },
          replyTo: nil, reactionGroups: [] }
      ] }
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
