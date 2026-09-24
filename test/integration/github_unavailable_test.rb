# frozen_string_literal: true

require "test_helper"

# `Github::Unavailable` — a 5xx, a timeout, or a connection failure — on every
# screen that can meet one.
#
# It is the one GitHub error where "try again" is honest advice, and it was
# also the one nothing rendered: `Github::Client#translate_errors` has raised
# it since the client existed, but only the three JSON endpoints rescued it, so
# GitHub having a bad five minutes reached the reviewer as Rails' generic 500 —
# and, on a Turbo form submission, as that 500 painted over the review screen
# with their unsent comment in it.
#
# These tests are deliberately about the *shape* of the answer rather than the
# wording: a status the browser and Turbo can act on, an explanation in the
# place the reviewer was looking, and — on a write — their own text handed back.
class GithubUnavailableTest < ActionDispatch::IntegrationTest
  OWNER = "acme"
  REPO = "docs-site"
  NUMBER = 42
  PATH = "docs/guide.md"
  THREAD_ID = "PRRT_kwDOABCD12MAAAAAAA1"

  PULL = "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}"

  setup { @user = users(:prism_dev) }

  # ------------------------------------------------------------- reading ---

  test "the Markdown tab says GitHub is unavailable rather than 500ing" do
    sign_in_as_user
    stub_github_error(:get, PULL, status: 503, message: "Service unavailable")

    get repo_pull_markdown_path(owner: OWNER, repo: REPO, number: NUMBER)

    assert_response :service_unavailable
    assert_select "[data-testid=empty-state]"
    assert_select "[data-testid=empty-state]", text: /unavailable|isn't answering|not answering/i
  end

  # The distinction the page has to make: GitHub being down is not the pull
  # request being gone, and only one of the two is worth retrying.
  test "an unavailable GitHub does not read as a missing pull request" do
    sign_in_as_user
    stub_github_error(:get, PULL, status: 502, message: "Bad gateway")

    get repo_pull_markdown_path(owner: OWNER, repo: REPO, number: NUMBER)

    assert_response :service_unavailable
    assert_select "[data-testid=empty-state]", text: /GitHub has nothing here/i, count: 0
    assert_select "a", text: /try again/i
  end

  test "a connection failure reaching GitHub is the same page as a 5xx" do
    sign_in_as_user
    stub_request(:get, "#{GithubStubs::API}#{PULL}").with(query: hash_including({})).to_timeout

    get repo_pull_markdown_path(owner: OWNER, repo: REPO, number: NUMBER)

    assert_response :service_unavailable
    assert_select "[data-testid=empty-state]"
  end

  test "the pull request list is a page too, not a 500" do
    sign_in_as_user
    stub_github_get("/repos/#{OWNER}/#{REPO}", fixture: :repo)
    stub_github_error(:get, "/repos/#{OWNER}/#{REPO}/pulls", status: 500, message: "Internal server error")

    get repo_pulls_path(owner: OWNER, repo: REPO)

    assert_response :service_unavailable
    assert_select "[data-testid=empty-state]"
  end

  # -------------------------------------------------------------- writing ---

  test "create hands the reviewer's text back in the composer instead of a 500" do
    sign_in_as_user
    stub_github_error(:get, PULL, status: 503, message: "Service unavailable")

    post repo_pull_comments_path(owner: OWNER, repo: REPO, number: NUMBER),
         params: create_params(body: "A paragraph I do not want to retype."),
         as: :turbo_stream

    assert_response :service_unavailable
    assert_match(/turbo-stream action="update" target="composer_block_1"/, response.body)
    assert_equal "A paragraph I do not want to retype.", composer_body_in_stream
    assert_match(/unavailable|try again/i, response.body)
  end

  test "create on a plain HTML request gets the full unavailable page" do
    sign_in_as_user
    stub_github_error(:get, PULL, status: 503, message: "Service unavailable")

    post repo_pull_comments_path(owner: OWNER, repo: REPO, number: NUMBER),
         params: create_params(body: "Hi")

    assert_response :service_unavailable
    assert_select "[data-testid=empty-state]"
  end

  test "reply says so in the thread it was writing into" do
    sign_in_as_user
    stub_github_error(:get, PULL, status: 503, message: "Service unavailable")

    post repo_pull_comment_replies_path(owner: OWNER, repo: REPO, number: NUMBER, id: 900_001),
         params: { thread_id: THREAD_ID, body: "Hi", review: "0" },
         as: :turbo_stream

    assert_response :service_unavailable
    assert_match(/turbo-stream action="replace" target="thread_#{THREAD_ID}"/, response.body)
    assert_match(/unavailable|try again/i, response.body)
  end

  test "resolving a thread says so in the thread" do
    sign_in_as_user
    stub_github_error(:post, "/graphql", status: 503, message: "Service unavailable")

    post repo_pull_thread_resolve_path(owner: OWNER, repo: REPO, number: NUMBER, id: THREAD_ID),
         as: :turbo_stream

    assert_response :service_unavailable
    assert_match(/turbo-stream action="replace" target="thread_#{THREAD_ID}"/, response.body)
  end

  test "a reaction says so on the comment it was writing to" do
    sign_in_as_user
    stub_github_error(:post, "/graphql", status: 503, message: "Service unavailable")

    post repo_pull_comment_reactions_path(owner: OWNER, repo: REPO, number: NUMBER, id: "PRRC_one"),
         params: { content: "+1", path: PATH },
         as: :turbo_stream

    assert_response :service_unavailable
    assert_match(/turbo-stream action="replace" target="comment_PRRC_one"/, response.body)
  end

  test "submitting a review sends the reviewer back with the reason instead of a 500" do
    sign_in_as_user
    stub_github_error(:post, "#{PULL}/reviews/80002/events", status: 503, message: "Service unavailable")

    post repo_pull_review_submit_path(owner: OWNER, repo: REPO, number: NUMBER, id: 80_002),
         params: { event: "COMMENT", body: "Looks good." }

    assert_redirected_to repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)
    assert_match(/unavailable|try again/i, flash[:alert])
  end

  test "discarding a review sends the reviewer back with the reason instead of a 500" do
    sign_in_as_user
    stub_request(:delete, "#{GithubStubs::API}#{PULL}/reviews/80002")
      .to_return(status: 503, body: { message: "Service unavailable" }.to_json, headers: GithubStubs::JSON_HEADERS)

    delete repo_pull_review_path(owner: OWNER, repo: REPO, number: NUMBER, id: 80_002)

    assert_redirected_to repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)
    assert_match(/unavailable|try again/i, flash[:alert])
  end

  # A pull request that 404s mid-write is the other half of the same promise:
  # whatever GitHub says, the paragraph the reviewer typed comes back with it.
  # Before this, the 404/403 path rendered a message with no form in it at all,
  # and the words were gone.
  test "a 404 on create hands the reviewer's text back too" do
    sign_in_as_user
    stub_github_error(:get, PULL, status: 404, message: "Not Found")

    post repo_pull_comments_path(owner: OWNER, repo: REPO, number: NUMBER),
         params: create_params(body: "Also worth keeping."),
         as: :turbo_stream

    assert_response :not_found
    assert_match(/turbo-stream action="update" target="composer_block_1"/, response.body)
    assert_equal "Also worth keeping.", composer_body_in_stream
  end

  test "a 403 on create hands the reviewer's text back too" do
    sign_in_as_user
    stub_github_error(:get, PULL, status: 403, message: "Resource not accessible")

    post repo_pull_comments_path(owner: OWNER, repo: REPO, number: NUMBER),
         params: create_params(body: "Kept through a refusal."),
         as: :turbo_stream

    assert_response :forbidden
    assert_match(/turbo-stream action="update" target="composer_block_1"/, response.body)
    assert_equal "Kept through a refusal.", composer_body_in_stream
  end

  private

  def create_params(body:)
    { path: PATH, line: 3, side: "RIGHT", subject_type: "line",
      body: body, commit: "single", block_id: "block_1" }
  end

  def sign_in_as_user
    stub_github_get("/user/repos", fixture: :repos)
    sign_in_as(@user)
  end

  # What is actually in the composer's textarea in the stream we just rendered.
  # A turbo_stream response wraps its markup in a `<template>`, which neither
  # `assert_select` nor a regex over the body can tell apart from the same
  # words appearing anywhere else — and "the reviewer's paragraph came back in
  # the box they typed it in" is the whole assertion.
  def composer_body_in_stream
    streams = Nokogiri::HTML5.fragment(response.body)
    inner = streams.css("turbo-stream template").map(&:inner_html).join

    Nokogiri::HTML5.fragment(inner).at_css("textarea[name='body']")&.text
  end
end
