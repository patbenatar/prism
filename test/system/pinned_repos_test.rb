# frozen_string_literal: true

require "application_system_test_case"

# Pinning a repo from /repos, driven through the browser so a broken Turbo
# Stream target or a missing partial shows up here rather than only in an
# integration test that never renders anything.
class PinnedReposTest < ApplicationSystemTestCase
  setup do
    @user = users(:prism_dev)
    stub_github_get("/user/repos", fixture: :repos)
    sign_in_as(@user)
    visit repos_path
  end

  test "pinning a repo moves it under a Pinned heading without a full page load" do
    assert_no_selector "[data-testid=pinned-repo-list]"

    within "[data-testid=repo-list]" do
      within("[data-testid=repo-row]", text: "scratchpad") { find("[data-testid=pin-button]").click }
    end

    assert_selector "[data-testid=pinned-repo-list]"
    within("[data-testid=pinned-repo-list]") { assert_text "scratchpad" }
    within("[data-testid=repo-list]") { assert_no_text "scratchpad" }

    assert_no_csp_violations
  end

  test "unpinning returns the repo to the plain list, and the heading disappears once nothing is pinned" do
    within("[data-testid=repo-row]", text: "scratchpad") { find("[data-testid=pin-button]").click }
    assert_selector "[data-testid=pinned-repo-list]"

    within("[data-testid=pinned-repo-list] [data-testid=repo-row]", text: "scratchpad") do
      find("[data-testid=unpin-button]").click
    end

    assert_no_selector "[data-testid=pinned-repo-list]"
    within("[data-testid=repo-list]") { assert_text "scratchpad" }
  end

  test "pinning survives a full page load" do
    within("[data-testid=repo-row]", text: "scratchpad") { find("[data-testid=pin-button]").click }
    assert_selector "[data-testid=pinned-repo-list]"

    visit repos_path

    assert_selector "[data-testid=pinned-repo-list]"
    within("[data-testid=pinned-repo-list]") { assert_text "scratchpad" }
  end
end
