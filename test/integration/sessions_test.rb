# frozen_string_literal: true

require "test_helper"

class SessionsTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:prism_dev)
    # Signing in lands on the repository list, so every test that follows the
    # redirect needs that page's GitHub call stubbed.
    stub_github_get("/user/repos", fixture: :repos)
  end

  test "the sign-in page is reachable signed out and explains the repo scope" do
    get sign_in_path

    assert_response :success
    assert_select "[data-testid=sign-in]"
    assert_match(/repo/, response.body)
    assert_select "[data-testid=top-bar]", false, "a signed-out page has no app chrome"
  end

  test "a signed-in visitor is sent on from the sign-in page" do
    sign_in_as(@user)

    get sign_in_path

    assert_redirected_to repos_path
  end

  test "the OmniAuth callback signs the user in and lands on the repositories" do
    mock_github_auth(@user)

    post "/auth/github"
    follow_redirect!

    # The root path redirects to /repos rather than duplicating the action.
    assert_redirected_to root_path
    assert_equal @user.id, session[:user_id]
    follow_redirect!
    assert_redirected_to repos_path
    assert_match(/Signed in as #{@user.login}/, flash[:notice].to_s)
  end

  test "the callback creates a user the first time an account signs in" do
    new_user = User.new(github_id: 99_123, login: "newcomer", name: "New Comer",
                        avatar_url: "https://avatars.githubusercontent.com/u/99123?v=4",
                        access_token: "gho_new")
    mock_github_auth(new_user)

    assert_difference -> { User.count }, 1 do
      post "/auth/github"
      follow_redirect!
    end

    assert_equal "newcomer", User.find(session[:user_id]).login
  end

  test "an OmniAuth failure sends the user back to sign in" do
    get "/auth/failure", params: { message: "invalid_credentials", strategy: "github" }

    assert_redirected_to sign_in_path
    assert_match(/Nothing was changed/, flash[:alert].to_s)
  end

  test "signing out clears the session" do
    sign_in_as(@user)

    delete session_path

    assert_redirected_to sign_in_path
    assert_nil session[:user_id]
  end

  test "signing in returns the visitor to where they were headed" do
    stub_github_get("/repos/acme/docs-site", fixture: :repo)
    stub_github_get("/repos/acme/docs-site/pulls", fixture: :pulls)

    get repo_pulls_path(owner: "acme", repo: "docs-site")
    assert_redirected_to sign_in_path

    sign_in_as(@user, follow: false)

    assert_redirected_to repo_pulls_path(owner: "acme", repo: "docs-site")
    follow_redirect!
    assert_response :success
  end
end
