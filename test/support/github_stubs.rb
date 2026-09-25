# frozen_string_literal: true

# WebMock helpers for the GitHub API.
#
# Network is disabled in tests, so every GitHub call must be stubbed explicitly.
# These helpers keep that from being tedious and, more importantly, make the
# assertions specific: a test should be able to say "we POSTed this exact
# GraphQL input" rather than "something happened".
#
# Fixtures live in test/fixtures/github/ and are shaped like real responses,
# including the awkward parts — a patch containing an empty-string context line,
# files with no `patch` key at all, an outdated thread whose `line` is null.
#
# Two of them are a shared contract, not private test data.
# test/services/review/github_fixture_contract_test.rb reads pull_files.json and
# review_threads.json and asserts the exact line sets and thread buckets the
# Markdown engine derives from them. That coupling is deliberate: it is what
# stops the client and the engine drifting apart silently. Changing the *shape*
# of either fixture — a hunk header, a status, a subjectType, a null line — will
# fail that test, and should. Adding or editing prose inside them will not.
module GithubStubs
  API = "https://api.github.com"
  JSON_HEADERS = { "Content-Type" => "application/json; charset=utf-8" }.freeze

  # ------------------------------------------------------------- fixtures ---

  def github_fixture_path(name)
    Rails.root.join("test/fixtures/github", name.to_s.include?(".") ? name.to_s : "#{name}.json")
  end

  # Raw file contents, for fixtures that are not JSON (Markdown source, rendered
  # HTML) or when a test wants to assert on the literal bytes.
  def github_fixture_raw(name) = File.read(github_fixture_path(name))

  def github_fixture(name)
    raw = github_fixture_raw(name)
    github_fixture_path(name).to_s.end_with?(".json") ? JSON.parse(raw) : raw
  end

  # ----------------------------------------------------------------- REST ---

  # `query:` defaults to matching any query string, because Octokit appends
  # per_page and friends that a test should not have to restate. Pass a hash to
  # pin the ones that matter.
  def stub_github_get(path, fixture: nil, body: nil, status: 200, query: nil, headers: {})
    stub_request(:get, "#{API}#{path}")
      .with(query: query || hash_including({}))
      .to_return(status: status, body: response_body(fixture, body), headers: JSON_HEADERS.merge(headers))
  end

  # Raw file contents come back as text, not JSON, when we send
  # Accept: application/vnd.github.raw.
  def stub_github_raw_get(path, fixture: nil, body: nil, status: 200, query: nil)
    stub_request(:get, "#{API}#{path}")
      .with(query: query || hash_including({}))
      .to_return(status: status, body: (fixture ? github_fixture_raw(fixture) : body.to_s),
                 headers: { "Content-Type" => "text/plain; charset=utf-8" })
  end

  # WebMock treats a URL with no query as "no query string at all", but Octokit
  # appends per_page to almost everything. Defaulting the matcher to
  # hash_including({}) keeps assertions about the path from failing over a query
  # the test never cared about.
  def assert_github_requested(method, path, query: hash_including({}), **options)
    assert_requested(method, "#{API}#{path}", query: query, **options)
  end

  def assert_github_not_requested(method, path, **options)
    assert_not_requested(method, "#{API}#{path}", **options)
  end

  # GitHub answers POST /markdown with HTML, not JSON. Getting the content type
  # wrong here makes Sawyer try to parse the HTML and blow up in the client.
  def stub_github_markdown(fixture: nil, body: nil, status: 200)
    stub_request(:post, "#{API}/markdown")
      .to_return(status: status,
                 body: fixture ? github_fixture_raw(fixture) : body.to_s,
                 headers: { "Content-Type" => "text/html; charset=utf-8" })
  end

  def stub_github_post(path, fixture: nil, body: nil, status: 201, request_body: nil, headers: {})
    stub = stub_request(:post, "#{API}#{path}")
    stub = stub.with(body: request_body) if request_body
    stub.to_return(status: status, body: response_body(fixture, body), headers: JSON_HEADERS.merge(headers))
  end

  def stub_github_patch(path, fixture: nil, body: nil, status: 200)
    stub_request(:patch, "#{API}#{path}")
      .to_return(status: status, body: response_body(fixture, body), headers: JSON_HEADERS)
  end

  def stub_github_delete(path, status: 204)
    stub_request(:delete, "#{API}#{path}").to_return(status: status, body: "", headers: JSON_HEADERS)
  end

  # An error response shaped the way GitHub shapes them, so Octokit's error
  # factory picks the class it would pick in production. That matters: Octokit
  # decides between Forbidden and TooManyRequests by matching the body text.
  def stub_github_error(method, path, status:, message: nil, errors: nil, headers: {})
    payload = { "message" => message || "Something went wrong",
                "documentation_url" => "https://docs.github.com/rest" }
    payload["errors"] = errors if errors

    stub_request(method, "#{API}#{path}")
      .with(query: hash_including({}))
      .to_return(status: status, body: payload.to_json, headers: JSON_HEADERS.merge(headers))
  end

  # ------------------------------------------------------------- GraphQL ---

  # Matches on the operation name parsed out of the document, so one test can
  # stub several mutations without their stubs colliding on the shared
  # POST /graphql URL.
  def stub_github_graphql(operation = nil, fixture: nil, data: nil, errors: nil, status: 200)
    payload =
      if fixture
        github_fixture(fixture)
      else
        {}.tap do |body|
          body["data"] = data if data
          body["errors"] = errors if errors
        end
      end

    stub = stub_request(:post, "#{API}/graphql")
    stub = stub.with { |request| graphql_operation_name(request.body) == operation.to_s } if operation
    stub.to_return(status: status, body: payload.is_a?(String) ? payload : payload.to_json, headers: JSON_HEADERS)
  end

  # Our documents always lead with the operation; fragments are appended after.
  def graphql_operation_name(raw_body)
    JSON.parse(raw_body.to_s)["query"].to_s[/\A\s*(?:query|mutation)\s+(\w+)/, 1]
  rescue JSON::ParserError
    nil
  end

  # Every GraphQL request made so far, newest last, as { operation:, query:,
  # variables: }. Useful when a test needs to assert the exact input object.
  def github_graphql_requests
    WebMock::RequestRegistry.instance.requested_signatures.hash.keys
                            .select { |signature| signature.uri.path == "/graphql" }
                            .filter_map do |signature|
      payload = JSON.parse(signature.body.to_s) rescue next
      { operation: graphql_operation_name(signature.body),
        query: payload["query"],
        variables: payload["variables"] || {} }
    end
  end

  # The variables of the last request for an operation. Fails loudly rather than
  # returning nil, so a typo in the operation name cannot masquerade as an
  # assertion that passed.
  def github_graphql_variables(operation)
    request = github_graphql_requests.reverse.find { |r| r[:operation] == operation.to_s }
    raise Minitest::Assertion, "No GraphQL request for operation #{operation.inspect}. " \
                               "Saw: #{github_graphql_requests.map { |r| r[:operation] }.inspect}" if request.nil?

    request[:variables]
  end

  def assert_github_graphql(operation, message = nil)
    variables = github_graphql_variables(operation)
    assert yield(variables), message || "GraphQL #{operation} variables did not match: #{variables.inspect}"
  end

  # The JSON body of the last POST/PATCH to a path, parsed.
  def github_request_body(method, path)
    signature = WebMock::RequestRegistry.instance.requested_signatures.hash.keys
                                        .reverse.find { |s| s.method == method && s.uri.path == path }
    raise Minitest::Assertion, "No #{method.to_s.upcase} request to #{path}" if signature.nil?

    JSON.parse(signature.body.to_s)
  end

  # ---------------------------------------------- OAuth token endpoint ---

  # Not api.github.com: renewing a token happens on the web host, the same
  # place omniauth exchanges the code during sign-in. See Github::Credentials.
  OAUTH_TOKEN_URL = "https://github.com/login/oauth/access_token"

  # A successful refresh. GitHub rotates the refresh token on every use, so
  # the default answer hands back a different one — a test that asserts the
  # *old* one was replaced is asserting the thing most likely to be got wrong.
  def stub_github_token_refresh(access_token: "gho_refreshed", refresh_token: "ghr_rotated",
                                expires_in: 28_800, refresh_token_expires_in: 15_897_600)
    body = { "access_token" => access_token, "token_type" => "bearer",
             "scope" => "repo,read:org,read:user" }
    body["expires_in"] = expires_in if expires_in
    body["refresh_token"] = refresh_token if refresh_token
    body["refresh_token_expires_in"] = refresh_token_expires_in if refresh_token

    stub_request(:post, OAUTH_TOKEN_URL).to_return(status: 200, body: body.to_json, headers: JSON_HEADERS)
  end

  # The trap this exists to exercise: GitHub answers a refused refresh with
  # **HTTP 200** and an `error` key. A stub that returns 401 would let a
  # status-code check pass a test it should fail.
  def stub_github_token_error(error, description: nil, status: 200)
    body = { "error" => error.to_s,
             "error_description" => description || "The refresh token passed is incorrect or expired.",
             "error_uri" => "https://docs.github.com/apps/oauth" }

    stub_request(:post, OAUTH_TOKEN_URL).to_return(status: status, body: body.to_json, headers: JSON_HEADERS)
  end

  def stub_github_token_unavailable(status: 502, body: "<html>Bad gateway</html>")
    stub_request(:post, OAUTH_TOKEN_URL).to_return(status: status, body: body)
  end

  def assert_token_refreshed(times: 1)
    assert_requested(:post, OAUTH_TOKEN_URL, times: times)
  end

  def assert_no_token_refresh
    assert_not_requested(:post, OAUTH_TOKEN_URL)
  end

  # Prism deployed without its OAuth App credentials. Renewing is impossible,
  # and the interesting question is whether that ends anybody's session.
  def without_oauth_app_credentials
    previous = ENV.values_at("GITHUB_CLIENT_ID", "GITHUB_CLIENT_SECRET")
    ENV["GITHUB_CLIENT_ID"] = ""
    ENV["GITHUB_CLIENT_SECRET"] = ""
    yield
  ensure
    ENV["GITHUB_CLIENT_ID"], ENV["GITHUB_CLIENT_SECRET"] = previous
  end

  # ---------------------------------------------------------------- cache ---

  # The test environment uses a null store, which is right for most tests and
  # useless for asserting that caching happens at all. This swaps in a real
  # store for the duration of a block.
  def with_memory_cache
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield Rails.cache
  ensure
    Rails.cache = original
  end

  private

  def response_body(fixture, body)
    return github_fixture_raw(fixture) if fixture
    return "" if body.nil?

    body.is_a?(String) ? body : body.to_json
  end
end
