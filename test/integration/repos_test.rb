# frozen_string_literal: true

require "test_helper"

class ReposTest < ActionDispatch::IntegrationTest
  setup { @user = users(:prism_dev) }

  test "signed out, the repository list sends you to sign in" do
    get repos_path

    assert_redirected_to sign_in_path
  end

  test "the root path lands on the repository list" do
    get root_path

    assert_redirected_to repos_path
  end

  test "signed in, it lists the repositories GitHub returned" do
    stub_github_get("/user/repos", fixture: :repos)
    sign_in_as(@user)

    get repos_path

    assert_response :success
    assert_select "[data-testid=repo-row]", minimum: 2
    assert_select "[data-testid=repo-list]"
    assert_match "docs-site", response.body
  end

  test "a private repository is marked as one" do
    stub_github_get("/user/repos", fixture: :repos)
    sign_in_as(@user)

    get repos_path

    assert_select "[data-testid=repo-row]", text: /Private/
  end

  test "each row links to that repository's pull requests" do
    stub_github_get("/user/repos", fixture: :repos)
    sign_in_as(@user)

    get repos_path

    assert_select "a[href=?]", repo_pulls_path(owner: "acme", repo: "docs-site")
  end

  test "the rows carry the text the client-side filter searches" do
    stub_github_get("/user/repos", fixture: :repos)
    sign_in_as(@user)

    get repos_path

    assert_select "[data-testid=repo-filter]"
    assert_select "[data-filter-text*=?]", "acme/docs-site"
  end

  test "an account with no repositories gets an empty state, not a blank page" do
    stub_github_get("/user/repos", body: [])
    sign_in_as(@user)

    get repos_path

    assert_response :success
    assert_select "[data-testid=empty-state]"
    assert_select "[data-testid=repo-row]", false
  end

  test "a full page offers to load the next one" do
    full_page = Array.new(Github::Client::PER_PAGE) do |index|
      github_fixture(:repos).first.merge("id" => index, "name" => "repo-#{index}",
                                         "full_name" => "acme/repo-#{index}")
    end
    stub_github_get("/user/repos", body: full_page)
    sign_in_as(@user)

    get repos_path

    assert_select "[data-testid=load-more]"
  end

  test "a partial page does not offer to load more" do
    stub_github_get("/user/repos", fixture: :repos)
    sign_in_as(@user)

    get repos_path

    assert_select "[data-testid=load-more]", false
  end

  test "link prefetching is off, so hovering a list doesn't spend the rate limit" do
    stub_github_get("/user/repos", fixture: :repos)
    sign_in_as(@user)

    get repos_path

    # Turbo 8 prefetches on hover. Every screen in Prism costs GitHub calls, so
    # a reviewer running their eye down a list would render every row's page.
    # Pinned here because removing the tag fails silently.
    assert_select "meta[name=turbo-prefetch][content=false]", 1
  end

  test "pinned repos render first, under their own heading" do
    stub_github_get("/user/repos", fixture: :repos)
    @user.pinned_repos.create!(owner: "prism-dev", name: "scratchpad")
    sign_in_as(@user)

    get repos_path

    assert_select "[data-testid=pinned-repo-list]"
    assert_select "[data-testid=pinned-repo-list] [data-testid=repo-row]", text: /scratchpad/
    # The pinned repo does not also appear in the plain list below.
    assert_select "[data-testid=repo-list] [data-testid=repo-row]", text: /scratchpad/, count: 0
  end

  test "with nothing pinned, the heading is omitted entirely" do
    stub_github_get("/user/repos", fixture: :repos)
    sign_in_as(@user)

    get repos_path

    assert_select "[data-testid=pinned-repo-list]", false
    assert_select "[data-testid=repo-list] [data-testid=repo-row]", minimum: 2
  end

  test "every row carries a pin toggle" do
    stub_github_get("/user/repos", fixture: :repos)
    sign_in_as(@user)

    get repos_path

    assert_select "[data-testid=pin-button]", minimum: 2
  end

  test "GitHub rate-limiting the token renders an explanation rather than a 500" do
    stub_github_get("/user/repos", fixture: :repos)
    sign_in_as(@user)

    stub_github_error(:get, "/user/repos", status: 403,
                      message: "API rate limit exceeded for user ID 4242.",
                      headers: { "X-RateLimit-Remaining" => "0",
                                 "X-RateLimit-Reset" => 10.minutes.from_now.to_i.to_s })

    get repos_path

    assert_response :too_many_requests
    assert_select "[data-testid=rate-limit-banner]"
    # GitHub told us when the limit lifts, so the page names the wait rather
    # than falling back to "a few minutes".
    assert_select "[data-testid=rate-limit-banner]", text: /Try again in \d+ minutes/
  end
end
