# frozen_string_literal: true

require "test_helper"

class PinnedReposControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:prism_dev)
    stub_github_get("/user/repos", fixture: :repos)
    sign_in_as(@user)
  end

  test "pinning a repo creates a record keyed by owner and name" do
    assert_difference -> { PinnedRepo.count }, 1 do
      post pinned_repos_path, params: { owner: "acme", repo: "docs-site" }
    end

    pin = PinnedRepo.last
    assert_equal "acme", pin.owner
    assert_equal "docs-site", pin.name
    assert_equal @user, pin.user
  end

  test "pinning the same repo twice is idempotent" do
    post pinned_repos_path, params: { owner: "acme", repo: "docs-site" }

    assert_no_difference -> { PinnedRepo.count } do
      post pinned_repos_path, params: { owner: "acme", repo: "docs-site" }
    end
  end

  test "a Turbo Stream request re-renders the pinned and unpinned panels" do
    post pinned_repos_path, params: { owner: "acme", repo: "docs-site" },
                             headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_select "turbo-stream[action=replace][target=repo-lists]"
    assert_select "[data-testid=pinned-repo-list] [data-testid=repo-row]", text: /docs-site/
  end

  test "a plain HTML request redirects back to the repository list" do
    post pinned_repos_path, params: { owner: "acme", repo: "docs-site" }

    assert_redirected_to repos_path
  end

  test "unpinning removes the record" do
    @user.pinned_repos.create!(owner: "acme", name: "docs-site")

    assert_difference -> { PinnedRepo.count }, -1 do
      delete pinned_repo_path(owner: "acme", repo: "docs-site")
    end
  end

  test "unpinning over Turbo Stream moves the row back into the unpinned panel" do
    @user.pinned_repos.create!(owner: "acme", name: "docs-site")

    delete pinned_repo_path(owner: "acme", repo: "docs-site"),
           headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_select "[data-testid=pinned-repo-list]", false
    assert_select "[data-testid=repo-list] [data-testid=repo-row]", text: /docs-site/
  end

  test "signed out, pinning redirects to sign in" do
    sign_out!

    post pinned_repos_path, params: { owner: "acme", repo: "docs-site" }

    assert_redirected_to sign_in_path
  end
end
