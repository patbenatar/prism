# frozen_string_literal: true

require "application_system_test_case"

# Journey 12: the review screen reached the way a reviewer actually reaches
# it, and a comment left from there.
#
# Every other write journey starts with `visit` — a cold page load, where
# every Stimulus controller connects against a document the browser just
# parsed. A reviewer never does that. They click: repositories → the
# repository → the pull request → the file, and each of those is a Turbo
# Drive visit, which swaps `<body>` and re-runs the importmap's modules
# against a document that was already alive. The two are not the same, and
# the difference has already cost this app once (#22, diagrams painting black
# after a Turbo visit — every test until then had used `visit`).
#
# So this journey asserts the ordinary thing (a comment reaches GitHub with
# the right anchor) about the unordinary path: three Turbo Drive visits deep,
# then back out to the overview and in again through the tab strip, with the
# comment still there because GitHub has it.
class ReachedByClickingTest < ApplicationSystemTestCase
  include FeatureHelpers

  OWNER = FeatureHelpers::FEATURE_OWNER
  REPO = FeatureHelpers::FEATURE_REPO
  NUMBER = FeatureHelpers::FEATURE_NUMBER
  PATH = "docs/guide.md"
  HEAD_SHA = FeatureHelpers::FEATURE_HEAD_SHA
  PR_NODE_ID = FeatureHelpers::FEATURE_PR_NODE_ID

  HEAD = <<~MARKDOWN
    # Guide

    This paragraph is brand new.
  MARKDOWN

  PATCH = [ "@@ -1,1 +1,3 @@", " # Guide", "+", "+This paragraph is brand new." ].join("\n")

  setup do
    @user = users(:prism_dev)

    stub_github_get("/user/repos", fixture: :repos)
    stub_github_get("/repos/#{OWNER}/#{REPO}", fixture: :repo)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls", fixture: :pulls,
                    query: hash_including({ "state" => "open" }))
    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER, files_body: files_json, reviews_body: [])
    stub_feature_mentionables(owner: OWNER, repo: REPO)
    stub_github_markdown(fixture: "markdown.html")
    stub_feature_contents(PATH, HEAD_SHA, HEAD, owner: OWNER, repo: REPO)
    stub_feature_review_threads([])
  end

  test "clicking all the way in from the repository list still leaves a comment GitHub accepts" do
    mock_github_auth(@user)
    visit root_path
    click_on "Continue with GitHub"

    assert_selector "[data-testid=repo-list]"
    click_on REPO, match: :first

    assert_selector "[data-testid=pull-request-list]"
    click_on "Rewrite the getting-started guide"

    # The file row on the overview is a link into the Markdown tab's anchor
    # for that file, not a screen of its own — so this is a Turbo Drive visit
    # that lands mid-document.
    assert_selector "[data-testid=markdown-files]"
    within "[data-testid=markdown-files]" do
      click_on "guide.md", match: :first
    end

    assert_selector "[data-testid=rendered-file] h1", text: "Guide"
    assert_current_path repo_pull_markdown_path(owner: OWNER, repo: REPO, number: NUMBER)
    assert page.current_url.end_with?("##{Review::Page.file_key(PATH)}"),
           "the file row should land on that file's anchor: #{page.current_url}"

    thread = feature_thread(node_id: "PRRT_clicked", path: PATH, line: 3,
                            comments: [ feature_comment(node_id: "PRRC_clicked", body: "Arrived here by clicking.") ])
    stub_github_graphql(:AddThread, data: { addPullRequestReviewThread: { thread: thread } })
    stub_feature_review_threads([ thread ])

    block = find("[data-testid=md-block][data-change=added]", match: :first)
    block_id = comment_on_block(block, body: "Arrived here by clicking.")

    assert_selector "#threads_#{block_id} [data-testid=thread]", text: "Arrived here by clicking.", wait: 5
    expect_github_received(:AddThread) do |vars|
      input = vars["input"]
      input["pullRequestId"] == PR_NODE_ID && input["path"] == PATH && input["line"] == 3 &&
        input["side"] == "RIGHT"
    end

    # Out to the overview and back in through the tab strip — the other way
    # into this screen, and the one that proves the comment is GitHub's now
    # rather than something this page is still holding in the DOM.
    find("[data-testid=tab-overview]").click
    assert_selector "[data-testid=markdown-files]"

    find("[data-testid=tab-markdown]").click
    assert_selector "[data-testid=thread]", text: "Arrived here by clicking."

    assert_no_csp_violations
  end

  private

  def files_json
    [ { "filename" => PATH, "status" => "modified", "additions" => 2, "deletions" => 0, "changes" => 2,
        "patch" => PATCH, "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{PATH}" } ].to_json
  end
end
