# frozen_string_literal: true

require "test_helper"

# ReviewsController: submit / discard the viewer's pending review.
#
# No `create` action or test here — see the controller's own comment (L1,
# independent review 2026-09-19): the route/action were unreachable dead
# code, removed rather than wired to a real affordance.
class ReviewsControllerTest < ActionDispatch::IntegrationTest
  OWNER = "acme"
  REPO = "docs-site"
  NUMBER = 42
  HEAD_SHA = "6dcb09b5b57875f334f61aebed695e2e4193db5e"

  setup { @user = users(:prism_dev) }

  test "signed out, submit redirects to sign in" do
    post repo_pull_review_submit_path(owner: OWNER, repo: REPO, number: NUMBER, id: 80002),
         params: { event: "APPROVE" }

    assert_redirected_to sign_in_path
  end

  test "submit APPROVE needs no body and redirects to the PR overview with a flash" do
    sign_in_as(@user)
    stub_github_post("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews/80002/events", fixture: :submitted_review)

    post repo_pull_review_submit_path(owner: OWNER, repo: REPO, number: NUMBER, id: 80002),
         params: { event: "APPROVE" }

    assert_redirected_to repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)
    assert_match(/approved/i, flash[:notice].to_s)
    assert_equal "APPROVE", github_request_body(:post, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews/80002/events")["event"]
  end

  # GitHub's rule is that a review must carry a body OR at least one comment —
  # not that non-approving reviews need prose. Verified against the real API:
  # COMMENT with neither is rejected, COMMENT with one draft comment and no body
  # succeeds. These two tests pin both halves, because the old behaviour blocked
  # an ordinary review where the reviewer had said everything inline.
  test "submit with no body and no comments is rejected before calling GitHub" do
    sign_in_as(@user)

    post repo_pull_review_submit_path(owner: OWNER, repo: REPO, number: NUMBER, id: 80002),
         params: { event: "REQUEST_CHANGES", body: "", pending_count: "0" }

    assert_redirected_to repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)
    assert_match(/can't be empty/i, flash[:alert].to_s)
    assert_github_not_requested :post, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews/80002/events"
  end

  test "submit with no body but drafted comments goes through to GitHub" do
    sign_in_as(@user)
    stub_github_post("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews/80002/events",
                      body: { id: 80002, node_id: "PRR_x", state: "CHANGES_REQUESTED", body: nil,
                              user: { login: "prism-dev" }, html_url: "https://github.com/acme/docs-site/pull/42",
                              submitted_at: "2026-09-23T00:00:00Z", commit_id: "6dcb09b" })

    post repo_pull_review_submit_path(owner: OWNER, repo: REPO, number: NUMBER, id: 80002),
         params: { event: "REQUEST_CHANGES", body: "", pending_count: "3" }

    assert_redirected_to repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)
    assert_equal "REQUEST_CHANGES",
                 github_request_body(:post, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews/80002/events")["event"]
  end

  test "submit REQUEST_CHANGES with a body calls GitHub" do
    sign_in_as(@user)
    stub_github_post("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews/80002/events",
                      body: { id: 80002, node_id: "PRR_x", state: "CHANGES_REQUESTED", body: "Needs work.",
                              user: { login: "prism-dev" }, html_url: "https://github.com/acme/docs-site/pull/42",
                              commit_id: HEAD_SHA }.to_json)

    post repo_pull_review_submit_path(owner: OWNER, repo: REPO, number: NUMBER, id: 80002),
         params: { event: "REQUEST_CHANGES", body: "Needs work." }

    assert_redirected_to repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)
    body = github_request_body(:post, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews/80002/events")
    assert_equal "REQUEST_CHANGES", body["event"]
    assert_equal "Needs work.", body["body"]
  end

  test "destroy discards the pending review" do
    sign_in_as(@user)
    stub_github_delete("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews/80002")

    delete repo_pull_review_path(owner: OWNER, repo: REPO, number: NUMBER, id: 80002)

    assert_github_requested :delete, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews/80002"
  end
end
