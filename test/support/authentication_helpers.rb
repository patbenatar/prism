# frozen_string_literal: true

# Signing in from a test.
#
# There is no password to post, so `sign_in_as` drives the real OmniAuth flow in
# test mode: it installs a mock auth hash built from the user's fixture
# attributes, POSTs the request phase, and follows the redirect into
# SessionsController. That exercises the actual callback rather than reaching
# into the session, so a break in User.from_omniauth or the callback shows up
# here instead of hiding until someone clicks the button.
#
# Both flavours are provided because the mechanics differ: an integration test
# drives Rack directly, while a system test has to go through the browser.
module AuthenticationHelpers
  # The shape omniauth-github produces. Two details matter and are easy to get
  # wrong: `uid` is a String, and the granted scope lives under `extra`, not
  # under `credentials`.
  def github_auth_hash(user, token: nil, scope: nil)
    OmniAuth::AuthHash.new(
      provider: "github",
      uid: user.github_id.to_s,
      info: {
        nickname: user.login,
        name: user.name,
        email: nil,
        image: user.avatar_url,
        urls: { "GitHub" => "https://github.com/#{user.login}" }
      },
      credentials: {
        token: token || user.access_token || "gho_test_token",
        expires: false
      },
      extra: {
        scope: scope || user.token_scopes || "repo,read:org,read:user",
        raw_info: {
          "id" => user.github_id,
          "login" => user.login,
          "name" => user.name,
          "avatar_url" => user.avatar_url
        }
      }
    )
  end

  # Installs the mock and returns it. Call this when you want to drive the flow
  # yourself, or to assert on a failure path.
  def mock_github_auth(user, **options)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:github] = github_auth_hash(user, **options)
  end

  def mock_github_auth_failure(reason = :invalid_credentials)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:github] = reason
  end

  def reset_github_auth
    OmniAuth.config.mock_auth[:github] = nil
    OmniAuth.config.test_mode = false
  end
end

# Integration tests: drive the request phase and follow OmniAuth's redirect into
# the callback.
module AuthenticationHelpers::Integration
  include AuthenticationHelpers

  # Drives the request phase and the callback, then stops.
  #
  # It deliberately does not follow on to wherever the app sends a freshly
  # signed-in user. Landing on that page would make every sign-in in the suite
  # depend on whatever GitHub calls that screen happens to make, so a test only
  # pays for the page it actually asks for. The response after this is the
  # redirect the callback issued.
  # Pass follow: true to continue on to the signed-in landing page, which then
  # needs whatever GitHub calls that screen makes to be stubbed.
  def sign_in_as(user, follow: false, **options)
    mock_github_auth(user, **options)

    post "/auth/github"
    follow_redirect!   # OmniAuth test mode -> /auth/github/callback

    # Stay inside the auth flow if it bounces again; stop at the app's own
    # destination without requesting it.
    follow_redirect! while response.redirect? && response.location.include?("/auth/")

    if follow
      5.times do
        break unless response.redirect?

        follow_redirect!
      end
    end

    user
  end

  def sign_out!
    delete "/session"
  end
end

# System tests: the browser has to make the POST, so click the real sign-in
# button rather than forging the request.
module AuthenticationHelpers::System
  include AuthenticationHelpers

  def sign_in_as(user, **options)
    mock_github_auth(user, **options)

    visit "/sign_in"
    click_on "Continue with GitHub"
    assert_no_current_path "/sign_in", wait: 5

    user
  end
end
