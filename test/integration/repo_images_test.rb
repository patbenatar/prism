# frozen_string_literal: true

require "test_helper"

# The image proxy. Everything a rendered Markdown document's `<img>` tags point
# at goes through this one action, made with the reader's own GitHub token, so
# these tests are mostly about the boundaries: what it refuses to serve, what it
# refuses to say, and what it tells a cache.
class RepoImagesTest < ActionDispatch::IntegrationTest
  OWNER = "acme"
  REPO = "docs-site"
  SHA = "6dcb09b5b57875f334f61aebed695e2e4193db5e"
  PATH = "docs/images/chart.png"
  CONTENTS = "/repos/#{OWNER}/#{REPO}/contents"

  setup do
    @user = users(:prism_dev)
    @png = file_fixture("chart.png").binread
    @svg = file_fixture("diagram.svg").binread
  end

  def image_path(path = PATH, ref: SHA, owner: OWNER, repo: REPO)
    repo_raw_path(owner: owner, repo: repo, ref: ref, path: path)
  end

  def stub_blob(path = PATH, body:, status: 200)
    stub_request(:get, "#{GithubStubs::API}#{CONTENTS}/#{path}")
      .with(query: hash_including({ "ref" => SHA }))
      .to_return(status: status, body: body,
                 headers: { "Content-Type" => "application/vnd.github.raw; charset=utf-8" })
  end

  # ------------------------------------------------------------- the happy ---

  test "serves the blob's bytes, sniffing the type from them" do
    sign_in_as(@user)
    stub_blob(body: @png)

    get image_path

    assert_response :success
    assert_equal "image/png", response.media_type
    assert_equal @png.bytesize, response.body.bytesize
    assert_equal Digest::SHA256.hexdigest(@png), Digest::SHA256.hexdigest(response.body.b),
                 "the bytes were altered on the way through"
  end

  test "fetches as the signed-in user and nobody else" do
    sign_in_as(@user)
    stub_blob(body: @png)

    get image_path

    assert_requested :get, "#{GithubStubs::API}#{CONTENTS}/#{PATH}",
                     query: hash_including({ "ref" => SHA }),
                     headers: { "Authorization" => "token #{@user.access_token}" }
  end

  test "requires a signed-in user" do
    get image_path

    assert_redirected_to sign_in_path
  end

  # ------------------------------------------------------------- the route ---

  # A branch name can contain slashes, which makes `:ref` and `*path`
  # ambiguous; the constraint means the app never has to guess.
  test "a ref that is not a commit sha does not route here" do
    sign_in_as(@user)

    get "/#{OWNER}/#{REPO}/raw/main/#{PATH}"

    assert_response :not_found
    assert_not_requested :get, %r{\A#{GithubStubs::API}/repos/}
  end

  test "a path with a dot in it keeps its extension rather than becoming a format" do
    sign_in_as(@user)
    stub_blob(body: @png)

    get image_path

    assert_equal "image/png", response.media_type
  end

  # --------------------------------------------------------------- refusals ---

  # The type comes from the bytes, never from the extension — the extension is
  # whatever the repository's author chose to call the file.
  test "a file that is not an image is refused, whatever it is called" do
    sign_in_as(@user)
    stub_blob("docs/images/evil.png", body: "<html><body><script>alert(1)</script></body></html>")

    get image_path("docs/images/evil.png")

    assert_placeholder :not_an_image
  end

  test "a document linked as a picture is refused rather than served as one" do
    sign_in_as(@user)
    stub_blob("docs/images/spec.pdf", body: file_fixture("not-an-image.pdf").binread)

    get image_path("docs/images/spec.pdf")

    assert_placeholder :not_an_image
  end

  test "a blob over the ceiling is refused" do
    sign_in_as(@user)
    stub_blob(body: "\x89PNG\r\n\x1A\n".b + ("\0" * RepoImagesController::MAX_BYTES))

    get image_path

    assert_placeholder :too_large
  end

  test "a path GitHub does not have is the placeholder, not a 404 page" do
    sign_in_as(@user)
    stub_github_error(:get, "#{CONTENTS}/docs/images/gone.png", status: 404, message: "Not Found")

    get image_path("docs/images/gone.png")

    assert_placeholder :not_found
  end

  # A repository the reader cannot see and one that does not exist have to be
  # indistinguishable, which is the same rule the rest of Prism follows: GitHub
  # answers 404 for both, and confirming a private repository exists is the
  # thing we are not willing to do.
  test "a repository the reader cannot see looks exactly like one that is empty" do
    sign_in_as(@user)
    stub_github_error(:get, "/repos/someone/private/contents/#{PATH}", status: 404, message: "Not Found")
    stub_github_error(:get, "#{CONTENTS}/docs/images/gone.png", status: 404, message: "Not Found")

    get image_path(owner: "someone", repo: "private")
    hidden = [ response.status, response.body, response.headers["X-Prism-Image"] ]

    get image_path("docs/images/gone.png")

    assert_equal hidden, [ response.status, response.body, response.headers["X-Prism-Image"] ]
  end

  test "a 403 from GitHub is the same placeholder" do
    sign_in_as(@user)
    stub_github_error(:get, "#{CONTENTS}/#{PATH}", status: 403, message: "Forbidden")

    get image_path

    assert_placeholder :not_found
  end

  test "a rate limit degrades to the placeholder rather than an error page" do
    sign_in_as(@user)
    stub_github_error(:get, "#{CONTENTS}/#{PATH}", status: 403,
                      message: "API rate limit exceeded",
                      headers: { "X-RateLimit-Remaining" => "0" })

    get image_path

    assert_placeholder :unavailable
  end

  test "GitHub being down degrades to the placeholder" do
    sign_in_as(@user)
    stub_github_error(:get, "#{CONTENTS}/#{PATH}", status: 503, message: "Service unavailable")

    get image_path

    assert_placeholder :unavailable
  end

  # ------------------------------------------------------------- traversal ---

  test "dot segments in the URL never reach GitHub" do
    sign_in_as(@user)
    stub_request(:get, %r{\A#{GithubStubs::API}/repos/}).to_return(status: 404, body: "{}")

    get "/#{OWNER}/#{REPO}/raw/#{SHA}/docs/../../../../etc/passwd"

    assert_requested :get, "#{GithubStubs::API}#{CONTENTS}/etc/passwd",
                     query: hash_including({ "ref" => SHA })
    assert_not_requested :get, %r{\.\.}
  end

  test "a path that is nothing but dot segments is refused before GitHub is asked" do
    sign_in_as(@user)

    get "/#{OWNER}/#{REPO}/raw/#{SHA}/../.."

    assert_placeholder :bad_path
    assert_not_requested :get, %r{\A#{GithubStubs::API}/repos/}
  end

  # ------------------------------------------------------------------- svg ---

  # An SVG is a document: it can carry script, and script in a same-origin
  # document is a stolen session. It is served, because diagrams in READMEs are
  # SVGs, but only under a policy that makes the document inert.
  test "an SVG is served under a policy that makes it inert" do
    sign_in_as(@user)
    stub_blob("docs/images/diagram.svg", body: @svg)

    get image_path("docs/images/diagram.svg")

    assert_response :success
    assert_equal "image/svg+xml", response.media_type
    assert_equal "default-src 'none'; sandbox", response.headers["Content-Security-Policy"]
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
  end

  test "every response is locked down, not just the SVGs" do
    sign_in_as(@user)
    stub_blob(body: @png)

    get image_path

    assert_equal "default-src 'none'; sandbox", response.headers["Content-Security-Policy"]
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
  end

  # ----------------------------------------------------------------- caching ---

  # The URL names a commit, so the bytes behind it can never change. `private`
  # is the word that matters: a shared cache must never hold one reader's view
  # of a repository that may be private.
  test "a served image is cacheable forever and only by the reader's own browser" do
    sign_in_as(@user)
    stub_blob(body: @png)

    get image_path

    directives = response.headers["Cache-Control"].to_s.split(",").map(&:strip)

    assert_includes directives, "private"
    assert_includes directives, "immutable"
    assert_includes directives, "max-age=31536000"
  end

  test "a revalidation is answered without asking GitHub again" do
    sign_in_as(@user)
    stub_blob(body: @png)

    get image_path
    etag = response.headers["ETag"]
    assert etag.present?

    get image_path, headers: { "If-None-Match" => etag }

    assert_response :not_modified
    assert_requested :get, "#{GithubStubs::API}#{CONTENTS}/#{PATH}",
                     query: hash_including({ "ref" => SHA }), times: 1
  end

  # Two people may have different access to the same private repository, so one
  # must never revalidate their way into the other's answer — the same rule
  # Github::Client's cache keys follow.
  test "the validator is namespaced by user" do
    sign_in_as(@user)
    stub_blob(body: @png)
    get image_path
    mine = response.headers["ETag"]

    delete session_path
    sign_in_as(users(:octocat))
    get image_path

    assert_not_equal mine, response.headers["ETag"]
  end

  # A failure must not be what the browser remembers at a URL whose whole point
  # is that its contents never change — otherwise a rate limit that lasted a
  # minute would blank a document's images for a year.
  test "a placeholder is never stored, and never validates into the real image" do
    sign_in_as(@user)
    missing = stub_github_error(:get, "#{CONTENTS}/#{PATH}", status: 404, message: "Not Found")

    get image_path

    assert_placeholder :not_found
    assert_includes response.headers["Cache-Control"].to_s, "no-store"
    stale = response.headers["ETag"]

    # The file lands in a later push, and the reader comes back holding
    # whatever validator the placeholder happened to carry.
    remove_request_stub(missing)
    stub_blob(body: @png)
    get image_path, headers: { "If-None-Match" => stale }

    assert_response :success
    assert_equal "image/png", response.media_type
  end

  private

  # Every failure looks the same from outside — same status, same bytes — so
  # that none of them is an oracle. The reason is a response header, for us.
  def assert_placeholder(reason)
    assert_response :success
    assert_equal "image/svg+xml", response.media_type
    assert_equal reason.to_s, response.headers["X-Prism-Image"]
    assert_includes response.body, "Image unavailable"
  end
end
