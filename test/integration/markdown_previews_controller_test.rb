# frozen_string_literal: true

require "test_helper"

# MarkdownPreviewsController#create — GitHub's own Markdown rendering for the
# composer's Write/Preview tab.
class MarkdownPreviewsControllerTest < ActionDispatch::IntegrationTest
  OWNER = "acme"
  REPO = "docs-site"

  setup { @user = users(:prism_dev) }

  test "signed out redirects to sign in" do
    post repo_markdown_preview_path(owner: OWNER, repo: REPO), params: { text: "hi" }

    assert_redirected_to sign_in_path
  end

  test "renders GitHub's own Markdown, sanitized, as an HTML fragment" do
    sign_in_as(@user)
    stub_github_markdown(fixture: "markdown.html")

    post repo_markdown_preview_path(owner: OWNER, repo: REPO), params: { text: "@octocat see #1" }

    assert_response :success
    assert_github_requested :post, "/markdown"
    body = github_request_body(:post, "/markdown")
    assert_equal "@octocat see #1", body["text"]
    assert_equal "gfm", body["mode"]
    assert_equal "#{OWNER}/#{REPO}", body["context"]
  end

  test "shows a small inline error instead of raising when GitHub fails" do
    sign_in_as(@user)
    stub_github_error(:post, "/markdown", status: 503, message: "GitHub is down")

    post repo_markdown_preview_path(owner: OWNER, repo: REPO), params: { text: "hi" }

    assert_response :success
    assert_match "unavailable", response.body
  end

  # M4 (independent review, 2026-09-19): a bare `rescue_from Github::Error`
  # here shadowed Authentication's own `rescue_from Github::Unauthorized`,
  # so a revoked token showed a small error fragment forever instead of
  # signing the user out and clearing it — mirrors MentionablesController's
  # own test for the same thing.
  test "a revoked token signs the user out instead of showing an inline error" do
    sign_in_as(@user)
    stub_github_error(:post, "/markdown", status: 401, message: "Bad credentials")

    post repo_markdown_preview_path(owner: OWNER, repo: REPO), params: { text: "hi" }

    assert_redirected_to sign_in_path
    assert_nil @user.reload.access_token
  end
end
