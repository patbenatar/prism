# frozen_string_literal: true

require "test_helper"

# ReferencesController#index — JSON for the `#` autocomplete.
class ReferencesControllerTest < ActionDispatch::IntegrationTest
  OWNER = "acme"
  REPO = "docs-site"

  setup { @user = users(:prism_dev) }

  test "signed out redirects to sign in" do
    get repo_references_path(owner: OWNER, repo: REPO)

    assert_redirected_to sign_in_path
  end

  test "returns pull requests and issues from the one issues endpoint" do
    sign_in_as(@user)
    stub_github_get("/repos/#{OWNER}/#{REPO}/issues", fixture: :issues)

    get repo_references_path(owner: OWNER, repo: REPO)

    assert_response :success
    body = JSON.parse(response.body)

    assert_equal %w[number title kind status], body.first.keys
    assert_equal [ 42, 41, 39, 37, 12 ], body.map { |item| item["number"] }
    assert_equal "pull_request", body.first["kind"]
    assert_equal "issue", body.second["kind"]
  end

  test "asks GitHub for every state, most recently touched first" do
    sign_in_as(@user)
    stub_github_get("/repos/#{OWNER}/#{REPO}/issues", fixture: :issues)

    get repo_references_path(owner: OWNER, repo: REPO)

    assert_github_requested(:get, "/repos/#{OWNER}/#{REPO}/issues",
                             query: hash_including({ "state" => "all", "sort" => "updated",
                                                     "direction" => "desc", "per_page" => "100" }))
  end

  # The word matters more than the colour: a reviewer about to link #39 needs
  # to know it is already merged, and "closed" would not say so.
  test "a merged pull request reads as merged and a draft as draft" do
    sign_in_as(@user)
    stub_github_get("/repos/#{OWNER}/#{REPO}/issues", fixture: :issues)

    get repo_references_path(owner: OWNER, repo: REPO)

    by_number = JSON.parse(response.body).index_by { |item| item["number"] }
    assert_equal "open",   by_number[42]["status"]
    assert_equal "merged", by_number[39]["status"]
    assert_equal "draft",  by_number[37]["status"]
    assert_equal "closed", by_number[12]["status"]
  end

  test "a repository with no pull requests or issues answers with an empty list" do
    sign_in_as(@user)
    stub_github_get("/repos/#{OWNER}/#{REPO}/issues", body: "[]")

    get repo_references_path(owner: OWNER, repo: REPO)

    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  # Issues can be disabled on a repository, which 404s here. Typing `#123` by
  # hand still links, so the menu going quiet is the whole cost.
  test "degrades to an empty list when the repository has issues disabled" do
    sign_in_as(@user)
    stub_github_error(:get, "/repos/#{OWNER}/#{REPO}/issues", status: 404, message: "Not Found")

    get repo_references_path(owner: OWNER, repo: REPO)

    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  test "degrades to an empty list rather than a 500 when GitHub rate-limits the request" do
    sign_in_as(@user)
    stub_github_error(:get, "/repos/#{OWNER}/#{REPO}/issues", status: 403,
                       message: "API rate limit exceeded", headers: { "Retry-After" => "30" })

    get repo_references_path(owner: OWNER, repo: REPO)

    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  # Rails.cache is a null store in the test environment, so the real caching
  # assertion lives in Github::ClientTest with a memory store swapped in. This
  # one checks the half that does not need a store: the controller asks the
  # client once per request and adds no reads of its own.
  test "one request costs one GitHub call" do
    sign_in_as(@user)
    stub_github_get("/repos/#{OWNER}/#{REPO}/issues", fixture: :issues)

    get repo_references_path(owner: OWNER, repo: REPO)

    assert_github_requested(:get, "/repos/#{OWNER}/#{REPO}/issues", times: 1)
  end
end
