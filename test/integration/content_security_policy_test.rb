# frozen_string_literal: true

require "test_helper"

# The header itself. The browser-level checks live in
# test/system/content_security_policy_test.rb; these pin the directives so a
# well-meaning loosening shows up as a failing test rather than as a quieter
# policy nobody notices.
class ContentSecurityPolicyTest < ActionDispatch::IntegrationTest
  setup { @user = users(:prism_dev) }

  def policy = response.headers["Content-Security-Policy"]

  test "the policy is enforced, not report-only" do
    get sign_in_path

    assert_response :success
    assert policy.present?, "no Content-Security-Policy header"
    assert_nil response.headers["Content-Security-Policy-Report-Only"]
  end

  test "it is served to a signed-out visitor as well as a signed-in one" do
    get sign_in_path
    signed_out = policy

    stub_github_get("/user/repos", fixture: :repos)
    sign_in_as(@user)
    get repos_path
    signed_in = policy

    assert signed_out.present?
    assert signed_in.present?
  end

  test "the directives are the ones DESIGN.md documents" do
    get sign_in_path

    assert_includes policy, "default-src 'self'"
    assert_includes policy, "font-src 'self' https://fonts.gstatic.com"
    assert_includes policy, "img-src 'self' https: data:"
    assert_includes policy, "connect-src 'self'"
    assert_includes policy, "frame-ancestors 'none'"
    assert_includes policy, "object-src 'none'"
    assert_includes policy, "base-uri 'self'"
    assert_includes policy, "form-action 'self' https://github.com"
  end

  test "scripts are same-origin with a nonce and never unsafe-inline" do
    get sign_in_path

    script_src = policy[/script-src [^;]+/]

    assert_includes script_src, "'self'"
    assert_match(/'nonce-[^']+'/, script_src)
    assert_not_includes script_src, "unsafe-inline"
    assert_not_includes script_src, "unsafe-eval"
  end

  test "inline styles are allowed only as attributes, for GitHub label colours" do
    get sign_in_path

    style_src = policy[/style-src [^;]+/]

    # Elements: origin plus a nonce, so Turbo's injected <style> works without
    # opening inline styles generally.
    assert_includes style_src, "https://fonts.googleapis.com"
    assert_match(/'nonce-[^']+'/, style_src)
    assert_not_includes style_src, "unsafe-inline"

    # Attributes: the one exception, and it carries no nonce — adding one would
    # silently cancel the unsafe-inline the label pills depend on.
    assert_includes policy, "style-src-attr 'unsafe-inline'"
  end

  test "the nonce in the header is the nonce on the script tags" do
    get sign_in_path

    nonce = policy[/script-src [^;]*'nonce-([^']+)'/, 1]
    assert nonce.present?, "no nonce in script-src"

    script_nonces = response.body.scan(/<script[^>]*\bnonce="([^"]*)"/).flatten
    assert script_nonces.any?, "no nonced <script> on the page"
    assert_equal [ nonce ], script_nonces.uniq

    # And the meta tag Turbo reads to nonce anything it injects later.
    assert_select "meta[name=csp-nonce][content=?]", nonce
  end

  test "every nonce is fresh, so one page's nonce can't authorise another's" do
    get sign_in_path
    first = policy[/'nonce-([^']+)'/, 1]

    get sign_in_path
    second = policy[/'nonce-([^']+)'/, 1]

    assert_not_equal first, second
  end

  test "a signed-out visitor still gets a usable nonce" do
    # Rails suggests deriving the nonce from the session id. A signed-out
    # visitor has no session yet, which would render `nonce-` and block every
    # script on the sign-in page — the one page a new user sees.
    get sign_in_path

    nonce = policy[/script-src [^;]*'nonce-([^']*)'/, 1]

    assert nonce.present?
    assert_operator nonce.length, :>, 8
  end
end
