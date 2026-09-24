# frozen_string_literal: true

require "test_helper"

# These tests guard the two things that make talking GraphQL through Octokit
# surprising. Both have bitten real projects and neither shows up as an obvious
# failure at the call site.
class Github::GraphQLTest < ActiveSupport::TestCase
  setup do
    @octokit = Octokit::Client.new(access_token: "gho_test", per_page: 100)
    @graphql = Github::GraphQL.new(@octokit)
  end

  test "the document travels in the request body, not the URL" do
    # Octokit::Connection#request does `options[:query] = data.delete(:query)`
    # on a Hash body, so a GraphQL payload passed as a Hash would have its query
    # lifted out of the body and appended to the URL as a parameter. Serializing
    # first is what avoids that, and this test fails loudly if anyone "tidies"
    # the JSON dump away.
    stub_github_graphql(data: { "viewer" => { "login" => "prism-dev" } })

    @graphql.call("query Viewer { viewer { login } }", foo: "bar")

    request = github_graphql_requests.last
    assert_equal "query Viewer { viewer { login } }", request[:query]
    assert_equal({ "foo" => "bar" }, request[:variables])

    assert_requested(:post, "#{GithubStubs::API}/graphql") do |signature|
      assert_nil signature.uri.query, "the query must not leak into the URL"
      true
    end
  end

  test "returns data as a plain symbol-keyed hash" do
    stub_github_graphql(data: { "repository" => { "pullRequest" => { "id" => "PR_1" } } })

    data = @graphql.call("query Q { x }")

    assert_instance_of Hash, data
    assert_equal "PR_1", data.dig(:repository, :pullRequest, :id)
  end

  test "nested objects are hashes, not Sawyer resources that could shadow a field" do
    # Sawyer::Resource resolves fields through method_missing, so a GraphQL field
    # sharing a name with one of its own methods would return the method instead
    # of the data. Converting to plain hashes removes the whole class of bug.
    stub_github_graphql(data: { "node" => { "url" => "https://example.test", "hash" => "abc" } })

    node = @graphql.call("query Q { x }")[:node]

    assert_instance_of Hash, node
    assert_equal "https://example.test", node[:url]
    assert_equal "abc", node[:hash]
  end

  test "raises on a non-empty errors array even though the status is 200" do
    stub_github_graphql(errors: [ { "message" => "Field 'nope' doesn't exist" } ])

    error = assert_raises(Github::GraphQLError) { @graphql.call("query Q { nope }") }

    assert_equal "Field 'nope' doesn't exist", error.message
    assert_equal 1, error.errors.size
  end

  test "joins several error messages" do
    stub_github_graphql(errors: [ { "message" => "first" }, { "message" => "second" } ])

    error = assert_raises(Github::GraphQLError) { @graphql.call("query Q { x }") }

    assert_equal "first; second", error.message
  end

  test "maps NOT_FOUND and FORBIDDEN onto the REST error classes" do
    stub_github_graphql(errors: [ { "message" => "Could not resolve to a node", "type" => "NOT_FOUND" } ])
    assert_raises(Github::NotFound) { @graphql.call("query Q { x }") }

    WebMock.reset!
    stub_github_graphql(errors: [ { "message" => "Resource not accessible", "type" => "FORBIDDEN" } ])
    assert_raises(Github::Forbidden) { @graphql.call("query Q { x }") }
  end

  test "reads a machine-readable type from extensions when there is no top-level type" do
    stub_github_graphql(errors: [ { "message" => "nope", "extensions" => { "code" => "NOT_FOUND" } } ])

    assert_raises(Github::NotFound) { @graphql.call("query Q { x }") }
  end

  test "errors are exposed with string keys for inspection" do
    stub_github_graphql(errors: [ { "message" => "boom", "path" => %w[repository pullRequest] } ])

    error = assert_raises(Github::GraphQLError) { @graphql.call("query Q { x }") }

    assert_equal "boom", error.errors.first["message"]
    assert_equal %w[repository pullRequest], error.errors.first["path"]
  end

  test "an error payload with no message still raises something legible" do
    stub_github_graphql(errors: [ { "type" => "INTERNAL" } ])

    error = assert_raises(Github::GraphQLError) { @graphql.call("query Q { x }") }

    assert_match(/GraphQL API returned an error/, error.message)
  end

  # This used to assert an empty hash, which is what let the production 500 of
  # 2026-09-24 happen: a mutation that answered with nothing looked to every
  # caller exactly like a successful write of nothing, and the nil travelled
  # until it reached a view. Neither data nor errors is not an empty result,
  # it is no result.
  test "a response with neither data nor errors is unconfirmed, not an empty hash" do
    stub_github_graphql(data: nil)

    error = assert_raises(Github::Unconfirmed) { @graphql.call("query Q { x }") }

    assert_match(/neither data nor errors/, error.message)
  end

  test "a response with an empty body is unconfirmed too" do
    stub_request(:post, "#{GithubStubs::API}/graphql")
      .to_return(status: 200, body: "", headers: GithubStubs::JSON_HEADERS)

    assert_raises(Github::Unconfirmed) { @graphql.call("query Q { x }") }
  end

  # `data` present and empty is a real, legitimate answer — a query that
  # matched nothing — and must stay distinguishable from no answer at all.
  test "a response with an empty data object is still a result" do
    stub_request(:post, "#{GithubStubs::API}/graphql")
      .to_return(status: 200, body: { data: {} }.to_json, headers: GithubStubs::JSON_HEADERS)

    assert_equal({}, @graphql.call("query Q { x }"))
  end

  test "an HTTP-level failure is still an Octokit error and is translated by the client" do
    # GraphQL is not immune to transport failures: a revoked token answers 401
    # on /graphql exactly as it would on a REST path.
    stub_request(:post, "#{GithubStubs::API}/graphql")
      .to_return(status: 401, body: { message: "Bad credentials" }.to_json,
                 headers: GithubStubs::JSON_HEADERS)

    assert_raises(Octokit::Unauthorized) { @graphql.call("query Q { x }") }
    assert_raises(Github::Unauthorized) do
      Github::Client.new(users(:prism_dev)).review_threads("acme", "docs-site", 42)
    end
  end
end
