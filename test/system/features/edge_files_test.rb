# frozen_string_literal: true

require "application_system_test_case"

# Journey 7: the edge shapes a pull request's file list can take — a removed
# file (rendered from BASE, commenting only on LEFT), a renamed file with no
# patch (nothing commentable), an added file (everything's added), a
# non-Markdown path (redirect to GitHub), and a path this PR never touched
# (404).
class EdgeFilesTest < ApplicationSystemTestCase
  include FeatureHelpers

  OWNER = FeatureHelpers::FEATURE_OWNER
  REPO = FeatureHelpers::FEATURE_REPO
  NUMBER = FeatureHelpers::FEATURE_NUMBER
  HEAD_SHA = FeatureHelpers::FEATURE_HEAD_SHA
  BASE_SHA = FeatureHelpers::FEATURE_BASE_SHA

  REMOVED_PATH = "docs/legacy.md"
  REMOVED_BASE = <<~MARKDOWN
    # Legacy

    This page is gone, but it used to explain the old setup flow in full.
  MARKDOWN
  REMOVED_PATCH = [
    "@@ -1,3 +0,0 @@",
    "-# Legacy",
    "-",
    "-This page is gone, but it used to explain the old setup flow in full."
  ].join("\n")

  RENAMED_PATH = "docs/install.md"
  RENAMED_PREVIOUS_PATH = "docs/installation.md"
  RENAMED_HEAD = "# Install\n\nRun the installer.\n"

  ADDED_PATH = "docs/troubleshooting.md"
  ADDED_HEAD = "# Troubleshooting\n\nIf the build fails, check the log.\n"
  ADDED_PATCH = [ "@@ -0,0 +1,3 @@", "+# Troubleshooting", "+", "+If the build fails, check the log." ].join("\n")

  NON_MD_PATH = "assets/diagram.png"
  UNKNOWN_PATH = "docs/nowhere.md"

  setup do
    @user = users(:prism_dev)

    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER, files_body: files_json,
                              reviews_body: [])
    stub_feature_mentionables(owner: OWNER, repo: REPO)
    stub_github_markdown(fixture: "markdown.html")
    stub_feature_review_threads([])

    stub_feature_contents(REMOVED_PATH, BASE_SHA, REMOVED_BASE, owner: OWNER, repo: REPO)
    stub_feature_contents(RENAMED_PATH, HEAD_SHA, RENAMED_HEAD, owner: OWNER, repo: REPO)
    stub_feature_contents(RENAMED_PREVIOUS_PATH, BASE_SHA, RENAMED_HEAD, owner: OWNER, repo: REPO)
    stub_feature_contents(ADDED_PATH, HEAD_SHA, ADDED_HEAD, owner: OWNER, repo: REPO)

    sign_in_for_feature(@user)
  end

  test "a removed file renders the base side, marked removed, commenting only on the LEFT" do
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: REMOVED_PATH)

    assert_selector "[data-testid=uncommentable-notice][data-kind=file_removed]"
    assert_selector "[data-testid=md-block][data-change=removed]", minimum: 2
    assert_text "This page is gone"

    block = find("[data-testid=md-block][data-commentable=true]", match: :first)
    # The "+" is opacity-0 until hover (DESIGN §7); Capybara/Selenium treat
    # that as not-visible, so read its data attributes with visible: :all.
    anchor = JSON.parse(block.find(".md-add", visible: :all)["data-anchor"])
    assert_equal "LEFT", anchor["side"]
    assert anchor["line"].is_a?(Integer), "a LEFT anchor still needs a base-side line: #{anchor.inspect}"

    thread = feature_thread(node_id: "PRRT_removed", path: REMOVED_PATH, line: anchor["line"],
                            diff_side: "LEFT",
                            comments: [ feature_comment(node_id: "PRRC_removed", body: "Sad to see this go.") ])
    stub_github_graphql(:AddThread, data: { addPullRequestReviewThread: { thread: thread } })
    stub_feature_review_threads([ thread ])

    comment_on_block(block, body: "Sad to see this go.")

    assert_selector "[data-testid=thread]", text: "Sad to see this go.", wait: 5
    expect_github_received(:AddThread) do |vars|
      input = vars["input"]
      input["path"] == REMOVED_PATH && input["side"] == "LEFT" && input["line"] == anchor["line"]
    end
  end

  test "a renamed file with no patch offers nothing commentable" do
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: RENAMED_PATH)

    assert_selector "[data-testid=uncommentable-notice][data-kind=no_patch]"
    assert_selector "[data-testid=md-block]", minimum: 1
    assert_selector "[data-testid=md-block][data-commentable=true]", count: 0
    assert_selector ".md-add--muted", minimum: 1, visible: :all
  end

  test "an added file is all added blocks, every one commentable" do
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: ADDED_PATH)

    assert_selector "[data-testid=md-block][data-change=added]", minimum: 2
    assert_selector "[data-testid=md-block][data-change=unchanged]", count: 0
    assert_selector "[data-testid=md-block][data-commentable=false]", count: 0
  end

  test "a non-Markdown path redirects out to GitHub instead of rendering" do
    # A real browser always *follows* a 3xx — there's no "stop before you get
    # there" toggle in Selenium — and this sandbox has no route to the real
    # github.com, so letting Chrome try would hang the whole suite rather than
    # fail this one test. Assert the Location header directly instead, over a
    # plain HTTP request (never through the browser) carrying the session
    # cookie the browser already holds, against Capybara's own local server.
    cookie_header = page.driver.browser.manage.all_cookies.map { |c| "#{c[:name]}=#{c[:value]}" }.join("; ")
    uri = URI.join(page.server_url, repo_pull_file_path(owner: OWNER, repo: REPO, number: NUMBER, path: NON_MD_PATH))

    response = Net::HTTP.start(uri.host, uri.port) { |http| http.get(uri.request_uri, "Cookie" => cookie_header) }

    assert_includes %w[302 303], response.code
    assert_match(%r{\Ahttps://github\.com/#{OWNER}/#{REPO}/blob/}, response["Location"])
  end

  test "a path this pull request never touched shows the friendly 404" do
    visit repo_pull_file_path(owner: OWNER, repo: REPO, number: NUMBER, path: UNKNOWN_PATH)

    assert_selector "[data-testid=empty-state]"
  end

  private

  def files_json
    [
      { "filename" => REMOVED_PATH, "status" => "removed", "additions" => 0, "deletions" => 3, "changes" => 3,
        "patch" => REMOVED_PATCH,
        "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{BASE_SHA}/#{REMOVED_PATH}" },
      { "filename" => RENAMED_PATH, "previous_filename" => RENAMED_PREVIOUS_PATH, "status" => "renamed",
        "additions" => 0, "deletions" => 0, "changes" => 0,
        "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{RENAMED_PATH}" },
      { "filename" => ADDED_PATH, "status" => "added", "additions" => 3, "deletions" => 0, "changes" => 3,
        "patch" => ADDED_PATCH,
        "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{ADDED_PATH}" },
      { "filename" => NON_MD_PATH, "status" => "modified", "additions" => 0, "deletions" => 0, "changes" => 0,
        "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{NON_MD_PATH}" }
    ].to_json
  end
end
