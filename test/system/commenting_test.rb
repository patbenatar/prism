# frozen_string_literal: true

require "application_system_test_case"

# The commenting write path, driven through a real browser against
# workstream D's rendered file view.
#
# GitHub is stubbed with WebMock throughout; the review-thread and
# pending-review reads change shape as the scenario progresses (a fresh
# comment, then a pending review), so those two endpoints are stubbed with a
# short *sequence* of responses via WebMock's `to_return(a, b, c, ...)` —
# each matching request gets the next one in order, and the last repeats for
# anything further.
class CommentingTest < ApplicationSystemTestCase
  OWNER = "acme"
  REPO = "docs-site"
  NUMBER = 42
  PATH = "docs/guide.md"
  HEAD_SHA = "6dcb09b5b57875f334f61aebed695e2e4193db5e"
  BASE_SHA = "1c2d3e4f5061728394a5b6c7d8e9f0a1b2c3d4e5"
  PR_NODE_ID = "PR_kwDOABCD12MAAAABc9Vk"

  HEAD = <<~MARKDOWN
    # Guide

    This paragraph is brand new.

    Another new paragraph here.
  MARKDOWN

  PATCH = [
    "@@ -1,2 +1,5 @@",
    " # Guide",
    " ",
    "+This paragraph is brand new.",
    "+",
    "+Another new paragraph here."
  ].join("\n")

  setup do
    @user = users(:prism_dev)

    # System tests share one browser session (`parallelize(workers: 1)`), and
    # another test in the suite resizes the window to phone width and does not
    # restore it — don't inherit that; the pending-review popover overflows a
    # narrow viewport.
    page.driver.browser.manage.window.resize_to(1440, 900)

    stub_github_get("/user/repos", fixture: :repos)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/files", body: files_json)
    stub_github_markdown(fixture: "markdown.html")
    stub_github_raw_get("/repos/#{OWNER}/#{REPO}/contents/#{PATH}", body: HEAD,
                        query: hash_including({ "ref" => HEAD_SHA }))
    stub_github_get("/repos/#{OWNER}/#{REPO}/collaborators", fixture: :collaborators)
    stub_github_get("/orgs/#{OWNER}/members", fixture: :org_members)

    stub_reviews_sequence([], [], [], github_fixture(:reviews))
    stub_review_threads_sequence([], [ thread_data("single") ],
                                  [ thread_data("single"), thread_data("draft1", pending: true) ],
                                  [ thread_data("single"), thread_data("draft1", pending: true),
                                    thread_data("draft2", pending: true) ])

    stub_github_graphql(:AddThread, data: { addPullRequestReviewThread: { thread: thread_data("single") } })
    stub_github_post("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", fixture: :pending_review)
  end

  test "comment, start a review with two comments, and submit it" do
    sign_in_as(@user)
    visit repo_pull_file_path(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    assert_selector "[data-testid=rendered-file]"

    # ---- a single comment, with an @-mention picked from the autocomplete --
    block = first("[data-testid=md-block][data-commentable=true]")
    block_id = block["data-block-id"]
    block.hover
    block.find(".md-add").click

    within "#composer_#{block_id}" do
      fill_in_body("Nice work @oct")
      assert_selector "[role=listbox] [role=option]", text: /octocat/i, wait: 5
      find("[role=option]", text: /octocat/i, match: :first).click

      click_on "Add single comment"
    end

    assert_selector "[data-testid=thread]", text: "Nice work @octocat", wait: 5

    # ---------------------------------------- start a review, two comments --
    stub_github_graphql(:AddThread, data: { addPullRequestReviewThread: { thread: thread_data("draft1", pending: true) } })
    second_block = all("[data-testid=md-block][data-commentable=true]")[1]
    second_block_id = second_block["data-block-id"]
    second_block.hover
    second_block.find(".md-add").click

    within "#composer_#{second_block_id}" do
      fill_in_body("First review comment")
      click_on "Start a review"
    end

    assert_selector "[data-testid=pending-count]", text: "1", wait: 5

    stub_github_graphql(:AddThread, data: { addPullRequestReviewThread: { thread: thread_data("draft2", pending: true) } })
    second_block.hover
    second_block.find(".md-add").click
    within "#composer_#{second_block_id}" do
      fill_in_body("Second review comment")
      click_on "Add review comment"
    end

    assert_selector "[data-testid=pending-count]", text: "2", wait: 5

    # --------------------------------------------------------------- submit --
    stub_github_post("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews/80002/events",
                      fixture: :submitted_review)

    find("[data-testid=review-submit-open]").click
    find("[data-testid=review-event-approve]", wait: 5).click
    click_on "Submit review"

    assert_current_path repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)
    assert_selector "[data-testid=flash]", text: /approved/i
  end

  private

  def fill_in_body(text)
    area = find("textarea", match: :first)
    area.click
    area.send_keys(text)
  end

  def files_json
    [ { "filename" => PATH, "status" => "modified", "additions" => 3, "deletions" => 0,
        "changes" => 3, "patch" => PATCH,
        "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{PATH}" } ].to_json
  end

  def thread_data(key, pending: false)
    {
      id: "PRRT_#{key}", path: PATH, line: 3, originalLine: 3, startLine: nil, originalStartLine: nil,
      diffSide: "RIGHT", startDiffSide: nil, subjectType: "LINE",
      isResolved: false, isOutdated: false, viewerCanResolve: true, viewerCanUnresolve: false,
      viewerCanReply: true, resolvedBy: nil,
      comments: { pageInfo: { hasNextPage: false, endCursor: nil }, nodes: [
        {
          id: "PRRC_#{key}", databaseId: rand(900_000..999_999),
          body: key == "single" ? "Nice work @octocat" : "#{key} body",
          bodyHTML: "<p>#{key == "single" ? "Nice work @octocat" : "#{key} body"}</p>",
          state: pending ? "PENDING" : "SUBMITTED", createdAt: "2026-09-19T10:00:00Z",
          url: "https://github.com/#{OWNER}/#{REPO}/pull/#{NUMBER}#discussion_r1",
          diffHunk: "", outdated: false, viewerCanUpdate: true, viewerCanDelete: true,
          viewerCanReact: !pending,
          author: { login: "prism-dev", avatarUrl: "https://avatars.githubusercontent.com/u/4242?v=4",
                    url: "https://github.com/prism-dev" },
          replyTo: nil, reactionGroups: []
        }
      ] }
    }
  end

  def stub_review_threads_sequence(*node_sets)
    responses = node_sets.map do |nodes|
      {
        status: 200,
        body: { data: { repository: { pullRequest: {
          id: PR_NODE_ID,
          reviewThreads: { pageInfo: { hasNextPage: false, endCursor: nil }, nodes: nodes }
        } } } }.to_json,
        headers: GithubStubs::JSON_HEADERS
      }
    end

    stub_request(:post, "#{GithubStubs::API}/graphql")
      .with { |request| graphql_operation_name(request.body) == "ReviewThreads" }
      .to_return(*responses)
  end

  def stub_reviews_sequence(*review_lists)
    responses = review_lists.map do |list|
      body = list.is_a?(String) ? list : list.to_json
      { status: 200, body: body, headers: GithubStubs::JSON_HEADERS }
    end

    stub_request(:get, "#{GithubStubs::API}/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews")
      .with(query: hash_including({}))
      .to_return(*responses)
  end
end
