# frozen_string_literal: true

require "test_helper"

class PullRequestsTest < ActionDispatch::IntegrationTest
  OWNER = "acme"
  REPO  = "docs-site"
  NUMBER = 42

  setup { @user = users(:prism_dev) }

  # ------------------------------------------------------------------ index --

  test "signed out, the pull request list sends you to sign in" do
    get repo_pulls_path(owner: OWNER, repo: REPO)

    assert_redirected_to sign_in_path
  end

  test "it lists the repository's pull requests" do
    sign_in_and_stub_index

    get repo_pulls_path(owner: OWNER, repo: REPO)

    assert_response :success
    assert_select "[data-testid=pull-request-row]", minimum: 2
    assert_match "Rewrite the getting-started guide", response.body
  end

  test "a draft pull request says so" do
    sign_in_and_stub_index

    get repo_pulls_path(owner: OWNER, repo: REPO)

    assert_select "[data-testid=pull-request-row]", text: /Draft/
  end

  test "labels render in the repository's own colors" do
    sign_in_and_stub_index

    get repo_pulls_path(owner: OWNER, repo: REPO)

    assert_select "[data-testid=labels] .label-pill", text: "documentation"
    assert_select ".label-pill[style*=?]", "#0075ca"
  end

  test "the state tabs link to each state and mark the current one" do
    sign_in_and_stub_index

    get repo_pulls_path(owner: OWNER, repo: REPO)

    assert_select "[data-testid=pr-tab-open][aria-current=page]"
    assert_select "[data-testid=pr-tab-closed]"
    assert_select "[data-testid=pr-tab-all]"
  end

  test "an unknown state falls back to open rather than asking GitHub for it" do
    sign_in_and_stub_index

    get repo_pulls_path(owner: OWNER, repo: REPO, state: "sideways")

    assert_response :success
    assert_select "[data-testid=pr-tab-open][aria-current=page]"
  end

  test "each row links to that pull request's overview" do
    sign_in_and_stub_index

    get repo_pulls_path(owner: OWNER, repo: REPO)

    assert_select "a[href=?]", repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)
  end

  test "a repository with no open pull requests gets an empty state" do
    sign_in_as_user
    stub_github_get("/repos/#{OWNER}/#{REPO}", fixture: :repo)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls", body: [])

    get repo_pulls_path(owner: OWNER, repo: REPO)

    assert_response :success
    assert_select "[data-testid=empty-state]"
  end

  test "a repository the token can't see renders the friendly 404" do
    sign_in_as_user
    stub_github_error(:get, "/repos/#{OWNER}/secret", status: 404, message: "Not Found")

    get repo_pulls_path(owner: OWNER, repo: "secret")

    assert_response :not_found
    assert_select "[data-testid=empty-state]"
  end

  # ------------------------------------------------------------------- show --

  test "the overview shows the pull request, its description and its files" do
    sign_in_and_stub_show

    get repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)

    assert_response :success
    assert_match "Rewrite the getting-started guide", response.body
    assert_select "[data-testid=pr-state]", text: "Open"
    assert_select "[data-testid=pr-body]"
    assert_select "[data-testid=markdown-files]"
  end

  test "Markdown files anchor into the Markdown tab and other files link out to GitHub" do
    sign_in_and_stub_show

    get repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)

    markdown_paths = github_fixture(:pull_files)
      .map { |file| file["filename"] }
      .select { |path| path.match?(/\.(md|markdown|mdx)\z/i) }

    assert markdown_paths.any?, "the fixture needs at least one Markdown file"
    markdown_paths.each do |path|
      assert_select "a[href=?]",
                    repo_pull_markdown_path(owner: OWNER, repo: REPO, number: NUMBER,
                                            anchor: Review::Page.file_key(path))
    end

    assert_select "[data-testid=other-files] a[href^=?]", "https://github.com/"
  end

  test "the tab strip names both screens, marks this one, and counts what is free" do
    sign_in_and_stub_show

    get repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)

    assert_select "[data-testid=pr-tabs]"
    assert_select "[data-testid=tab-overview].tab-active"
    assert_select "[data-testid=tab-overview][aria-current=page]"
    assert_select "[data-testid=tab-markdown][href=?]",
                  repo_pull_markdown_path(owner: OWNER, repo: REPO, number: NUMBER)
    assert_select "[data-testid=tab-markdown]", text: /Markdown\s*4/
    assert_select "[data-testid=tab-overview]", text: /Overview\s*5/
    # A comment count on the tabs would cost the overview a GraphQL call it
    # otherwise never makes, so the tabs carry only the two free counts.
    assert_github_not_requested(:post, "/graphql")
  end

  test "the Markdown file count is computed here, where the files are already loaded" do
    sign_in_and_stub_show

    get repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)

    expected = github_fixture(:pull_files).count { |file| file["filename"].match?(/\.(md|markdown|mdx)\z/i) }
    assert_select "[data-testid=markdown-count]", text: /#{expected} file/
  end

  test "the review decision comes from the submitted reviews" do
    sign_in_and_stub_show

    get repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)

    # The fixture's most recent review per author leaves changes requested.
    assert_select "[data-testid=review-decision]", text: "Changes requested"
    assert_select "[data-testid=reviews]"
  end

  test "a description GitHub can't render leaves the rest of the page intact" do
    sign_in_as_user
    stub_show_endpoints
    stub_github_error(:post, "/markdown", status: 500, message: "Server Error")

    get repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)

    assert_response :success
    assert_select "[data-testid=markdown-files]"
    assert_match "No description", response.body
  end

  test "a pull request that doesn't exist renders the friendly 404" do
    sign_in_as_user
    stub_github_error(:get, "/repos/#{OWNER}/#{REPO}/pulls/999", status: 404, message: "Not Found")

    get repo_pull_path(owner: OWNER, repo: REPO, number: 999)

    assert_response :not_found
  end

  private

  def sign_in_as_user
    stub_github_get("/user/repos", fixture: :repos)
    sign_in_as(@user)
  end

  def sign_in_and_stub_index
    sign_in_as_user
    stub_github_get("/repos/#{OWNER}/#{REPO}", fixture: :repo)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls", fixture: :pulls)
  end

  def sign_in_and_stub_show
    sign_in_as_user
    stub_show_endpoints
  end

  def stub_show_endpoints
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/files", fixture: :pull_files)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", fixture: :reviews)
    stub_github_markdown(fixture: "markdown.html")
  end
end
