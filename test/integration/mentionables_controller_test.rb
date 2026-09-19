# frozen_string_literal: true

require "test_helper"

# MentionablesController#index — JSON for the @-mention autocomplete.
class MentionablesControllerTest < ActionDispatch::IntegrationTest
  OWNER = "acme"
  REPO = "docs-site"

  setup { @user = users(:prism_dev) }

  test "signed out redirects to sign in" do
    get repo_mentionables_path(owner: OWNER, repo: REPO)

    assert_redirected_to sign_in_path
  end

  test "returns collaborators and org members as JSON" do
    sign_in_as(@user)
    stub_github_get("/repos/#{OWNER}/#{REPO}/collaborators", fixture: :collaborators)
    stub_github_get("/orgs/#{OWNER}/members", fixture: :org_members)

    get repo_mentionables_path(owner: OWNER, repo: REPO)

    assert_response :success
    body = JSON.parse(response.body)
    assert body.is_a?(Array)
    assert body.first.key?("login")
    assert body.first.key?("avatar_url")
  end

  test "degrades to an empty list rather than a 500 when GitHub rate-limits the request" do
    sign_in_as(@user)
    stub_github_error(:get, "/repos/#{OWNER}/#{REPO}/collaborators", status: 403,
                       message: "API rate limit exceeded", headers: { "Retry-After" => "30" })
    stub_github_get("/orgs/#{OWNER}/members", fixture: :org_members)

    get repo_mentionables_path(owner: OWNER, repo: REPO)

    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end
end
