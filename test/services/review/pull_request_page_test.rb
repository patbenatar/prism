# frozen_string_literal: true

require "test_helper"

# The shared half of the Markdown tab: one pull request, one file list, one
# reviewThreads call, and every file's content fetched at once rather than one
# after another.
class Review::PullRequestPageTest < ActiveSupport::TestCase
  OWNER = "acme"
  REPO  = "docs-site"
  NUMBER = 42
  BASE_SHA = "1c2d3e4f5061728394a5b6c7d8e9f0a1b2c3d4e5"
  setup do
    @user = users(:prism_dev)
    @client = Github::Client.new(@user)
  end

  # ------------------------------------------------------------- the shape --

  test "it builds one Review::Page per Markdown file, in the file list's order" do
    stub_pull_request

    page = load_page

    assert_equal %w[docs/guide.md docs/troubleshooting.md docs/legacy.md docs/install.md],
                 page.pages.map(&:path)
    assert_equal %w[assets/diagram.png], page.other_files.map(&:path)
    assert page.any_markdown?
  end

  test "every file shares one reviewThreads call and filters it by its own path" do
    stub_pull_request

    page = load_page

    assert_requested(:post, "https://api.github.com/graphql", times: 1)
    guide = page.pages.first
    assert guide.threads.any?, "docs/guide.md has threads in the fixture"
    assert guide.threads.all? { |thread| thread.path == "docs/guide.md" }
  end

  test "the pending count is the pull request's, so the tray is the same on every file" do
    stub_pull_request

    page = load_page

    assert_equal 1, page.pending_count
    assert_equal [ 1 ], page.pages.map(&:pending_count).uniq
  end

  test "a file is fetched once even when two of them want the same base blob" do
    stub_pull_request

    load_page

    assert_requested(:get, %r{/contents/docs/guide\.md}, times: 2) # head and base
  end

  # -------------------------------------------------------- doing it at once --

  test "the file contents are fetched concurrently, not one after another" do
    # Four Markdown files, each content read held open for 120ms. Sequentially
    # that is at least 480ms before the first block could be rendered; in one
    # pool it is one wait. The margin is wide on purpose — this asserts that
    # the calls overlap at all, not how fast the machine is.
    stub_pull_request(content_delay: 0.12)

    # Warm first, then measure. The first call inside each worker thread can
    # trigger an autoload, and Rails serializes those — on a cold CI runner
    # that one-time cost lands squarely on the number we are timing and makes
    # genuinely concurrent fetches look sequential. Nothing else carries over:
    # the test environment's cache is a null store, so the second pass still
    # does all four reads and all four parses.
    load_page

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    load_page
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 0.4,
                    "four slow GitHub reads took #{(elapsed * 1000).round}ms, against 480ms if " \
                    "they ran one after another — they are not overlapping"
  end

  test "a content fetch that fails takes down its own file and nothing else" do
    stub_pull_request
    stub_request(:get, %r{/contents/docs/troubleshooting\.md})
      .to_return(status: 500, body: { message: "Server Error" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    page = load_page

    broken = page.pages.find { |file_page| file_page.path == "docs/troubleshooting.md" }
    assert_equal :unavailable, broken.content_problem
    assert broken.content_error.is_a?(Github::Error)
    assert broken.content_error_message.present?, "the notice quotes GitHub's own sentence"

    others = page.pages.reject { |file_page| file_page.path == "docs/troubleshooting.md" }
    assert others.all?(&:renderable?), "one bad fetch must not blank the other files"
    assert_not page.rate_limited?, "a 500 is not a rate limit"
  end

  test "a rate-limited content fetch is the page's problem as well as the file's" do
    # One file rate-limited means the next thing the reviewer does will be
    # too, so the page raises the banner while the file keeps its own
    # sentence — and every other document still renders.
    stub_pull_request
    stub_request(:get, %r{/contents/docs/troubleshooting\.md})
      .to_return(status: 403, body: { message: "API rate limit exceeded" }.to_json,
                 headers: { "Content-Type" => "application/json", "X-RateLimit-Remaining" => "0" })

    page = load_page

    assert page.rate_limited?
    assert_equal :unavailable,
                 page.pages.find { |file_page| file_page.path == "docs/troubleshooting.md" }.content_problem
    assert page.pages.first.renderable?
  end

  test "a 404 on a file is the ordinary missing-side case, not an error" do
    stub_pull_request
    stub_request(:get, %r{/contents/docs/troubleshooting\.md})
      .to_return(status: 404, body: "{}", headers: { "Content-Type" => "application/json" })

    broken = load_page.pages.find { |file_page| file_page.path == "docs/troubleshooting.md" }

    assert_equal :missing_content, broken.content_problem
    assert_nil broken.content_error
  end

  test "a base side that fails still leaves the document readable" do
    # The base is only ever the removed strips. Losing them is a loss; losing
    # the document over them would be a bigger one.
    stub_pull_request
    stub_request(:get, %r{/contents/docs/guide\.md})
      .with(query: hash_including({ "ref" => BASE_SHA }))
      .to_return(status: 500, body: { message: "Server Error" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    guide = load_page.pages.first

    assert_equal "docs/guide.md", guide.path
    assert guide.renderable?
    assert_nil guide.content_problem
  end

  # ------------------------------------------------------------- degradation --

  test "threads failing leaves every document readable and says so once" do
    stub_pull_request(threads: false)
    stub_request(:post, "https://api.github.com/graphql")
      .to_return(status: 500, body: { message: "Server Error" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    page = load_page

    assert page.threads_unavailable?
    assert_not page.rate_limited?
    assert page.threads_error_message.present?
    assert_equal 4, page.pages.count(&:renderable?)
    assert page.pages.all?(&:threads_unavailable?), "the banner is the page's, the state is every file's"
  end

  test "a rate limit on the threads call is its own state, with a reset time" do
    stub_pull_request(threads: false)
    stub_request(:post, "https://api.github.com/graphql")
      .to_return(status: 403, body: { message: "API rate limit exceeded" }.to_json,
                 headers: { "Content-Type" => "application/json", "X-RateLimit-Remaining" => "0" })

    page = load_page

    assert page.rate_limited?
    assert page.threads_unavailable?
  end

  # --------------------------------------------------------- the render budget --

  test "past the rendering budget a file is listed but not rendered" do
    # Concurrency fixes the network; nothing fixes the CPU cost of parsing,
    # so a pull request with more Markdown than Prism will render in one
    # request stops rendering rather than holding the thread.
    stub_pull_request

    page = with_render_budget(40) { load_page }

    assert_equal 4, page.pages.size, "every file is still listed"
    assert page.pages.first.renderable?, "the first file is always rendered"
    deferred = page.pages.select(&:deferred?)
    assert deferred.any?, "the budget should have run out"
    assert_equal :deferred, deferred.first.content_problem
    assert_nil deferred.first.result
  end

  test "under the budget nothing is deferred" do
    stub_pull_request

    page = load_page

    assert_equal [], page.pages.select(&:deferred?)
  end

  private

  def load_page
    Review::PullRequestPage.load(github: @client, owner: OWNER, repo: REPO, number: NUMBER)
  end

  def with_render_budget(bytes)
    original = Review::PullRequestPage::RENDER_BUDGET_BYTES
    silence_warnings { Review::PullRequestPage.const_set(:RENDER_BUDGET_BYTES, bytes) }
    yield
  ensure
    silence_warnings { Review::PullRequestPage.const_set(:RENDER_BUDGET_BYTES, original) }
  end

  def stub_pull_request(threads: true, content_delay: nil)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/files", fixture: :pull_files)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", fixture: :reviews)
    stub_github_graphql(:ReviewThreads, fixture: :review_threads) if threads

    stub_request(:get, %r{\Ahttps://api\.github\.com/repos/#{OWNER}/#{REPO}/contents/})
      .with(query: hash_including({}))
      .to_return do
        sleep content_delay if content_delay
        { status: 200, body: "# A file\n\nA paragraph of prose.\n\nAnd a second one.\n",
          headers: { "Content-Type" => "text/plain; charset=utf-8" } }
      end
  end
end
