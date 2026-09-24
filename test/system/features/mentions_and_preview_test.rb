# frozen_string_literal: true

require "application_system_test_case"

# Journey 8: comment autocomplete on both triggers — `@` for people
# (collaborators + org members) and `#` for the repository's issues and pull
# requests — in the composer and in a reply box, plus the Write/Preview tabs
# backed by GitHub's own /markdown endpoint.
class MentionsAndPreviewTest < ApplicationSystemTestCase
  include FeatureHelpers

  OWNER = FeatureHelpers::FEATURE_OWNER
  REPO = FeatureHelpers::FEATURE_REPO
  NUMBER = FeatureHelpers::FEATURE_NUMBER
  PATH = "docs/guide.md"
  HEAD_SHA = FeatureHelpers::FEATURE_HEAD_SHA
  PR_NODE_ID = FeatureHelpers::FEATURE_PR_NODE_ID

  HEAD = <<~MARKDOWN
    # Guide

    This paragraph is brand new.
  MARKDOWN

  PATCH = [ "@@ -1,1 +1,3 @@", " # Guide", "+", "+This paragraph is brand new." ].join("\n")

  setup do
    @user = users(:prism_dev)

    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER, files_body: files_json,
                              reviews_body: [])
    stub_feature_mentionables(owner: OWNER, repo: REPO)
    stub_feature_references(owner: OWNER, repo: REPO)
    stub_feature_contents(PATH, HEAD_SHA, HEAD, owner: OWNER, repo: REPO)

    sign_in_for_feature(@user)
  end

  # ------------------------------------------------------------------- @ ---

  test "typing @oc opens the mention listbox, and arrow+enter inserts the login" do
    open_file
    block_id = open_composer_for(first_block)

    within "#composer_#{block_id}" do
      area = find("textarea", match: :first)
      area.click
      area.send_keys("Nice work @oc")

      assert_selector "[role=listbox] [role=option]", text: /octocat/i, wait: 5

      area.send_keys(:down)
      area.send_keys(:enter)

      assert_field type: "textarea", with: "Nice work @octocat ", match: :first
    end
  end

  # GitHub's own menu shows an avatar, the login and the real name, because
  # two accounts whose logins differ by one character are otherwise the same
  # row twice.
  test "a person's row carries their avatar, login and real name" do
    open_file
    block_id = open_composer_for(first_block)

    within "#composer_#{block_id}" do
      find("textarea", match: :first).send_keys("@octo")

      option = find("[role=listbox] [role=option]", match: :first, wait: 5)
      assert_equal "octocat", option.find("span", match: :first).text
      assert_includes option.text, "The Octocat"
      assert option.has_css?("img[src*='avatars.githubusercontent.com']")
    end
  end

  test "the mention menu matches a real name as well as a login" do
    open_file
    block_id = open_composer_for(first_block)

    within "#composer_#{block_id}" do
      find("textarea", match: :first).send_keys("@Octocat")

      assert_selector "[role=listbox] [role=option]", text: "The Octocat", wait: 5
    end
  end

  # A trigger only opens a menu where a reference could actually start.
  test "no menu opens on the @ inside an email address" do
    open_file
    block_id = open_composer_for(first_block)

    within "#composer_#{block_id}" do
      area = find("textarea", match: :first)

      # Positive control first, so "no menu" below cannot pass merely because
      # the candidate fetch had not come back yet.
      area.send_keys("@oc")
      assert_selector "[role=listbox] [role=option]", wait: 5

      area.send_keys([ :control, "a" ], "write to nick@oc")
      assert_no_selector "[role=listbox] [role=option]"
    end
  end

  test "no menu opens inside a fenced code block, where a reference cannot link" do
    open_file
    block_id = open_composer_for(first_block)

    within "#composer_#{block_id}" do
      area = find("textarea", match: :first)
      area.send_keys("@oc")
      assert_selector "[role=listbox] [role=option]", wait: 5

      area.send_keys([ :control, "a" ], "```ruby")
      area.send_keys(:enter)
      area.send_keys("user = \"@oc")

      assert_no_selector "[role=listbox] [role=option]"
    end
  end

  # ------------------------------------------------------------------- # ---

  test "typing #rewrite finds the pull request by title, and arrow+enter inserts its number" do
    open_file
    block_id = open_composer_for(first_block)

    within "#composer_#{block_id}" do
      area = find("textarea", match: :first)
      area.click
      area.send_keys("Superseded by #rewrite")

      assert_selector "[role=listbox] [role=option]", text: "Rewrite the getting-started guide", wait: 5

      area.send_keys(:down)
      area.send_keys(:enter)

      assert_field type: "textarea", with: "Superseded by #42 ", match: :first
    end
  end

  test "typing #1 narrows by number" do
    open_file
    block_id = open_composer_for(first_block)

    within "#composer_#{block_id}" do
      find("textarea", match: :first).send_keys("See #12")

      options = all("[role=listbox] [role=option]", minimum: 1, wait: 5)
      assert_equal [ "#12" ], options.map { |option| option.text(:all)[/#\d+/] }
      assert_includes options.first.text, "Typos in the CLI reference"
    end
  end

  # An issue and a pull request share one number space, so the row has to say
  # which it is — in a word as well as an icon, because nothing in Prism is
  # carried by colour alone.
  test "a reference row names its kind and state" do
    open_file
    block_id = open_composer_for(first_block)

    within "#composer_#{block_id}" do
      find("textarea", match: :first).send_keys("#")

      rows = all("[role=listbox] [role=option]", minimum: 4, wait: 5).to_h { |row| [ row.text(:all)[/#\d+/], row.text(:all) ] }

      assert_includes rows["#42"], "open"
      assert_includes rows["#39"], "merged"
      assert_includes rows["#37"], "draft"
      assert_includes rows["#41"], "Issue"
      assert_includes rows["#42"], "Pull request"
    end
  end

  test "no menu opens on a # in the middle of a word" do
    open_file
    block_id = open_composer_for(first_block)

    within "#composer_#{block_id}" do
      area = find("textarea", match: :first)
      area.send_keys("#4")
      assert_selector "[role=listbox] [role=option]", wait: 5

      area.send_keys([ :control, "a" ], "colour is ffaa00#4")
      assert_no_selector "[role=listbox] [role=option]"
    end
  end

  # ------------------------------------------------------- reaching GitHub ---

  test "a reference picked from the menu reaches GitHub in the comment body" do
    open_file
    block_id = open_composer_for(first_block)

    stub_github_graphql(:AddThread, data: { addPullRequestReviewThread: { thread: posted_thread } })

    within "#composer_#{block_id}" do
      area = find("textarea", match: :first)
      area.click
      area.send_keys("Superseded by #rewrite")
      assert_selector "[role=listbox] [role=option]", wait: 5
      area.send_keys(:down)
      area.send_keys(:enter)

      click_on "Add single comment"
    end

    assert_selector "[data-testid=thread]", text: "Superseded by #42", wait: 5
    expect_github_received(:AddThread) { |vars| vars["input"]["body"] == "Superseded by #42 " }
  end

  # ---------------------------------------------------------- reply box ---

  test "both triggers work in a reply box, and the picked reference is what gets replied" do
    root = feature_comment(node_id: "PRRC_root", database_id: 900_100, body: "Worth a second look?")
    stub_feature_review_threads([ feature_thread(node_id: "PRRT_reply", path: PATH, line: 3, comments: [ root ]) ])
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
    assert_selector "[data-testid=thread]", text: "Worth a second look?"

    stub_github_post("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/comments/900100/replies",
                      body: {
                        id: 900_101, node_id: "PRRC_reply",
                        user: { login: "prism-dev", avatar_url: "https://avatars.githubusercontent.com/u/4242?v=4",
                                html_url: "https://github.com/prism-dev" },
                        body: "cc @octocat re #42", created_at: Time.current.iso8601,
                        html_url: "https://github.com/#{OWNER}/#{REPO}/pull/#{NUMBER}#discussion_r900101",
                        diff_hunk: "", line: 3, side: "RIGHT", subject_type: "line"
                      }.to_json)

    within "[data-testid=thread]" do
      area = find("[data-testid=reply-textarea]")
      area.click

      area.send_keys("cc @oc")
      assert_selector "[role=listbox] [role=option]", text: /octocat/i, wait: 5
      area.send_keys(:down)
      area.send_keys(:enter)

      area.send_keys("re #rewrite")
      assert_selector "[role=listbox] [role=option]", text: "Rewrite the getting-started guide", wait: 5
      area.send_keys(:down)
      area.send_keys(:enter)

      assert_equal "cc @octocat re #42 ", area.value

      click_on "Reply"
    end

    assert_selector "[data-testid=thread]", text: "cc @octocat re #42", wait: 5
    body = github_request_body(:post, "/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/comments/900100/replies")
    assert_equal "cc @octocat re #42 ", body["body"]
  end

  # ----------------------------------------------------------- edit form ---

  # The third editor. The composer and the reply box are covered above, and
  # the edit form wires the same controller in the same way — which is
  # exactly why it is worth one test: it is the surface most likely to be
  # forgotten when that wiring changes, and it already lost a hidden field
  # once (docs/testing.md, "A real bug this tier found").
  test "the mention menu works when editing a comment, and the picked login is what gets saved" do
    own = feature_comment(node_id: "PRRC_own", database_id: 900_300, body: "Original wording.",
                          author_login: "prism-dev", viewer_can_update: true, viewer_can_delete: true)
    stub_feature_review_threads([ feature_thread(node_id: "PRRT_own", path: PATH, line: 3, comments: [ own ]) ])
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)

    click_on "Edit"

    edited = feature_comment(node_id: "PRRC_own", database_id: 900_300, body: "Original wording. cc @octocat",
                             author_login: "prism-dev", viewer_can_update: true, viewer_can_delete: true)
    stub_github_graphql(:UpdateComment,
                        data: { updatePullRequestReviewComment: { pullRequestReviewComment: edited } })

    within "[data-testid=comment-edit-form]" do
      area = find("[data-testid=comment-edit-textarea]")
      area.click
      area.send_keys(" cc @oc")

      assert_selector "[role=listbox] [role=option]", text: /octocat/i, wait: 5
      area.send_keys(:down)
      area.send_keys(:enter)

      click_on "Save"
    end

    assert_selector "[data-testid=comment]", text: "cc @octocat", wait: 5
    expect_github_received(:UpdateComment) do |vars|
      vars["input"]["pullRequestReviewCommentId"] == "PRRC_own" &&
        vars["input"]["body"] == "Original wording. cc @octocat "
    end
  end

  # --------------------------------------------------------------- preview ---

  test "the Preview tab renders through GitHub's /markdown and Write keeps the text" do
    open_file
    block_id = open_composer_for(first_block)

    stub_github_markdown(fixture: "markdown.html")

    within "#composer_#{block_id}" do
      area = find("textarea", match: :first)
      area.click
      area.send_keys("Nice catch, @octocat see #12")

      click_on "Preview"
      assert_selector "[data-markdown-preview-target=previewBody] a.user-mention", text: "octocat", wait: 5

      # The claim this feature rests on: GitHub's own renderer, given the
      # repository as context, turns a bare #123 into a link. If it did not,
      # an inserted reference would look broken until the page reloaded.
      assert_selector "[data-markdown-preview-target=previewBody] a[href$='/issues/12']", text: "#12"
    end

    expect_github_received(:post, "/markdown") do |body|
      body["text"] == "Nice catch, @octocat see #12" && body["mode"] == "gfm" && body["context"] == "#{OWNER}/#{REPO}"
    end

    within "#composer_#{block_id}" do
      click_on "Write"
      assert_field type: "textarea", with: "Nice catch, @octocat see #12"
    end
  end

  private

  # The common start: a file with no threads on it yet, open on screen.
  def open_file
    stub_feature_review_threads([])
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PATH)
  end

  def first_block
    find("[data-testid=md-block][data-commentable=true]", match: :first)
  end

  def posted_thread
    comment = feature_comment(node_id: "PRRC_posted", database_id: 900_900,
                               body: "Superseded by #42", author_login: "prism-dev")
    feature_thread(node_id: "PRRT_posted", path: PATH, line: 3, comments: [ comment ])
  end

  def files_json
    [ { "filename" => PATH, "status" => "modified", "additions" => 2, "deletions" => 0, "changes" => 2,
        "patch" => PATCH, "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{PATH}" } ].to_json
  end
end
