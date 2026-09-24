# frozen_string_literal: true

require "test_helper"

# The sign-in flow end to end, driven through the real OmniAuth request and
# callback phases rather than by writing to the session.
class AuthenticationTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:prism_dev)
    stub_github_get("/user/repos", fixture: :repos)
  end

  test "a protected page redirects to sign in" do
    get repos_path

    assert_redirected_to sign_in_path
    assert_equal "Sign in with GitHub to continue.", flash[:alert]
  end

  test "signing in through the OmniAuth callback creates the session" do
    sign_in_as @user

    assert_response :redirect
    assert_equal @user.id, session[:user_id]

    follow_redirect!
    assert_redirected_to repos_path
  end

  test "signing in returns the user to the page they asked for" do
    get repo_pulls_path(owner: "acme", repo: "docs-site")
    assert_redirected_to sign_in_path

    stub_github_get("/repos/acme/docs-site/pulls", fixture: :pulls)
    stub_github_get("/repos/acme/docs-site", fixture: :repo)

    mock_github_auth(@user)
    post "/auth/github"
    follow_redirect!

    # reset_session on sign-in must not take the stored path with it.
    assert_redirected_to repo_pulls_path(owner: "acme", repo: "docs-site")
  end

  test "a protected non-GET request is not stored as a return path" do
    delete session_path

    assert_redirected_to sign_in_path
    assert_response :see_other, "Turbo only follows a redirect from a non-GET when it is a 303"
  end

  test "signing in rotates the session id" do
    get repos_path
    before = session.id

    sign_in_as @user

    assert_not_equal before, session.id
  end

  test "the first sign-in creates the user from the auth hash" do
    newcomer = User.new(github_id: 555_000, login: "brand-new", name: "Brand New",
                        avatar_url: "https://avatars.example/555000", access_token: "gho_new")

    assert_difference -> { User.count }, 1 do
      mock_github_auth(newcomer)
      post "/auth/github"
      follow_redirect!
    end

    created = User.find_by(github_id: 555_000)
    assert_equal "brand-new", created.login
    assert_equal "gho_new", created.access_token
    assert_equal created.id, session[:user_id]
  end

  test "signing out clears the session" do
    sign_in_as @user
    assert_equal @user.id, session[:user_id]

    delete session_path

    assert_nil session[:user_id]
    assert_redirected_to sign_in_path
  end

  test "a declined authorization lands on the failure page, not an exception" do
    mock_github_auth_failure(:access_denied)

    post "/auth/github"
    follow_redirect! while response.redirect? && response.location.include?("/auth/")

    assert_redirected_to sign_in_path
    assert_nil session[:user_id]
  end

  test "a revoked token signs the user out and clears the stored token" do
    sign_in_as @user
    WebMock.reset!
    stub_github_error(:get, "/user/repos", status: 401, message: "Bad credentials")

    get repos_path

    assert_redirected_to sign_in_path
    assert_nil session[:user_id]
    assert_nil @user.reload.access_token
    assert_match(/GitHub refused your sign-in/i, flash[:alert])
  end

  test "a signed-in user visiting sign in is sent onwards" do
    sign_in_as @user

    get sign_in_path

    assert_redirected_to repos_path
  end

  test "the sign-in page is reachable while signed out" do
    get sign_in_path

    assert_response :success
  end

  test "the sign-in button posts, because OmniAuth 2 refuses a GET request phase" do
    get sign_in_path

    assert_select "form[action='/auth/github'][method='post']"
  end

  test "a session pointing at a deleted user is treated as signed out" do
    sign_in_as @user
    @user.destroy!

    get repos_path

    assert_redirected_to sign_in_path
  end

  test "every GitHub request is made with the signed-in user's own token" do
    sign_in_as @user
    get repos_path

    assert_github_requested :get, "/user/repos",
                            headers: { "Authorization" => "token gho_test_token_prism_dev" },
                            at_least_times: 1
  end
end
