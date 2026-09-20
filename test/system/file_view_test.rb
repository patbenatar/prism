# frozen_string_literal: true

require "application_system_test_case"

# The rendered file view, driven through a real browser.
#
# The document here is built in the test rather than taken from the shared
# fixtures, because the screen only shows what it is for when the file has the
# things a docs pull request actually changes: an alert, a table that gains a
# row, a list that gains two items, a fenced code block that changes, and a
# paragraph that disappears.
class FileViewTest < ApplicationSystemTestCase
  OWNER = "acme"
  REPO = "docs-site"
  NUMBER = 42
  PATH = "docs/deploy.md"
  HEAD_SHA = "6dcb09b5b57875f334f61aebed695e2e4193db5e"
  BASE_SHA = "1c2d3e4f5061728394a5b6c7d8e9f0a1b2c3d4e5"
  SCREENSHOTS = Rails.root.join("tmp/screenshots")
  LIST_SELECTOR = "[data-testid=rendered-file] ol"

  HEAD = <<~MARKDOWN
    # Deployment guide

    This guide covers how Prism ships to production.

    > [!NOTE]
    > Deploys are gated on a green build.

    ## Environments

    | Environment | URL | Owner |
    | --- | --- | --- |
    | Staging | staging.example.com | platform |
    | Production | example.com | platform |

    ## Steps

    1. Merge to `main`.
    2. Wait for the build to pass.
    3. Run `bin/deploy production`.

    ```bash
    bin/deploy production --confirm
    ```

    Old paragraph that survives.
  MARKDOWN

  BASE = <<~MARKDOWN
    # Deployment guide

    This guide covers how Prism ships to production.

    A paragraph this pull request deletes.

    ## Environments

    | Environment | URL | Owner |
    | --- | --- | --- |
    | Staging | staging.example.com | platform |

    ## Steps

    1. Merge to `main`.

    ```bash
    bin/deploy production
    ```

    Old paragraph that survives.

    A closing note this pull request drops.
  MARKDOWN

  # Written as lines rather than a heredoc: a blank context line in a unified
  # diff is a single space, which a heredoc's indentation stripping would eat.
  PATCH = [
    "@@ -1,8 +1,9 @@",
    " # Deployment guide",
    " ",
    " This guide covers how Prism ships to production.",
    " ",
    "-A paragraph this pull request deletes.",
    "+> [!NOTE]",
    "+> Deploys are gated on a green build.",
    " ",
    " ## Environments",
    " ",
    "@@ -9,5 +10,6 @@",
    " | Environment | URL | Owner |",
    " | --- | --- | --- |",
    " | Staging | staging.example.com | platform |",
    "+| Production | example.com | platform |",
    " ",
    " ## Steps",
    "@@ -14,10 +16,10 @@",
    " ",
    " 1. Merge to `main`.",
    "+2. Wait for the build to pass.",
    "+3. Run `bin/deploy production`.",
    " ",
    " ```bash",
    "-bin/deploy production",
    "+bin/deploy production --confirm",
    " ```",
    " ",
    " Old paragraph that survives.",
    "-",
    "-A closing note this pull request drops."
  ].join("\n")

  setup do
    @user = users(:prism_dev)
    FileUtils.mkdir_p(SCREENSHOTS)

    # The browser is reused between tests and the phone-width test leaves it
    # at 390, where the gutter "+" is deliberately always visible. Start every
    # test on a laptop.
    resize(1440, 900)

    stub_github_get("/user/repos", fixture: :repos)
    stub_github_get("/repos/#{OWNER}/#{REPO}", fixture: :repo)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls", fixture: :pulls)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/files", body: files_json)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", fixture: :reviews)
    stub_github_markdown(fixture: "markdown.html")
    stub_contents(PATH, HEAD_SHA, HEAD)
    stub_contents(PATH, BASE_SHA, BASE)
    stub_contents("docs/changelog.md", HEAD_SHA, "# Changelog\n\nNothing yet.\n")
    stub_github_graphql(:ReviewThreads, data: threads_response)
  end

  test "reading a pull request's Markdown file, rendered" do
    sign_in_as(@user)
    visit repo_pull_path(owner: OWNER, repo: REPO, number: NUMBER)

    click_on "deploy.md", match: :first

    # The document is rendered, not shown as a diff.
    assert_selector "[data-testid=rendered-file] h1", text: "Deployment guide"
    assert_selector "[data-testid=rendered-file] h2", text: "Environments"
    assert_selector "[data-testid=rendered-file] table td", text: "staging.example.com"
    assert_selector "[data-testid=rendered-file] pre", text: "bin/deploy production --confirm"
    assert_selector ".markdown-alert", text: "Deploys are gated on a green build"

    # And the changes are bands down the left edge, not a wall of green.
    assert_selector "[data-testid=md-block][data-change=added]", minimum: 3
    assert_selector "[data-testid=md-block][data-change=unchanged]", minimum: 2
    assert_selector "[data-testid=changed-count]", text: /changed block/
  end

  test "hovering a changed block reveals its + and an unchanged one stays quiet" do
    open_file

    changed = find("[data-testid=md-block][data-change=added]", match: :first)
    button = changed.find(".md-add", visible: :all)

    assert_equal "0", opacity(button), "the + is out of the way until you reach for the block"
    changed.hover
    assert_equal "1", opacity(button)
    assert_equal "true", button["data-commentable"]
  end

  test "a table row carries its own + and its own thread slot" do
    open_file

    row = find("tr.md-child[data-commentable=true]", match: :first)
    assert row["data-block-id"].present?

    block_id = row["data-block-id"]
    assert_selector "##{"threads_#{block_id}"}", visible: :all
    assert_selector "##{"composer_#{block_id}"}", visible: :all
    assert_selector "tr.md-thread-row[data-thread-row-for='#{block_id}']", visible: :all
  end

  test "a removed paragraph is a collapsed strip you can open" do
    open_file

    strip = first("[data-testid=removed-strip]")
    assert_no_text "A paragraph this pull request deletes"
    assert_text "1 block removed"

    strip.find("summary").click

    assert_text "A paragraph this pull request deletes"
    assert_selector "[data-testid=removed-strip]", text: "Hide"
  end

  test "content deleted from the end of the file is a strip after the last block" do
    open_file

    # Two strips: one where a paragraph was cut from the middle, one for the
    # closing note, which has no following block to sit before.
    strips = all("[data-testid=removed-strip]")
    assert_equal 2, strips.size

    trailing = strips.last
    assert_no_text "A closing note this pull request drops"

    trailing.find("summary").click
    assert_text "A closing note this pull request drops"

    # It is the end of this document, below every block *of this file*.
    last_block = section.all("[data-testid=md-block]").last
    assert_operator trailing.rect.y, :>, last_block.rect.y,
                    "the trailing strip renders after the last block"
    assert_equal 0, trailing.all(".md-add", visible: :all).size,
                 "deleted lines have no RIGHT side to anchor a comment to"
  end

  test "n and p jump between the blocks this pull request changed" do
    open_file

    assert_selector "[data-testid=changed-count]", text: /^\d+ changed blocks$/

    find("body").send_keys("n")
    assert_selector "[data-testid=changed-count]", text: /^1 of \d+ changed blocks$/

    find("body").send_keys("n")
    assert_selector "[data-testid=changed-count]", text: /^2 of \d+ changed blocks$/

    find("body").send_keys("p")
    assert_selector "[data-testid=changed-count]", text: /^1 of \d+ changed blocks$/
  end

  test "n walks straight out of one file and into the next" do
    open_file

    # The page holds every Markdown file in the pull request, so the walk is
    # through the *review*, not through a file. Press "n" until it runs out of
    # changes in docs/deploy.md and it lands in docs/changelog.md rather than
    # wrapping back to the top of the file it started in.
    total = find("[data-testid=changed-count]").text[/(\d+) changed/, 1].to_i
    here = section.all("[data-testid=md-block][data-change]:not([data-change=unchanged])").size
    assert_operator total, :>, here, "the count is the whole pull request's, not this file's"

    total.times { find("body").send_keys("n") }
    assert_selector "[data-testid=changed-count]", text: /^#{total} of #{total} changed blocks$/

    landed = page.evaluate_script("document.activeElement.closest('[data-file-path]').dataset.filePath")
    assert_equal "docs/changelog.md", landed, "the last change in the pull request is in the second file"
  end

  test "the file switcher moves between the pull request's Markdown files" do
    open_file

    find("[data-testid=file-switcher] summary").click
    assert_selector "[data-testid=file-switcher-item]", minimum: 2

    within "[data-testid=file-switcher-menu]" do
      click_on "changelog.md", match: :first
    end

    assert_selector "[data-testid=file-switcher] summary", text: "changelog.md"
  end

  test "it looks right at 1440 and at 390" do
    open_file
    all("[data-testid=removed-strip] summary").each(&:click)
    save_screenshot(SCREENSHOTS.join("file_view_1440.png"))
    assert_operator horizontal_overflow, :<=, 1, "the file view scrolls sideways at 1440px"

    # The lower half of the document, with a table row hovered so the gutter
    # affordances are in the picture.
    page.execute_script("document.querySelector('#{LIST_SELECTOR}').scrollIntoView({block: 'center'})")
    find("li.md-child", match: :first).hover
    save_screenshot(SCREENSHOTS.join("file_view_1440_gutter.png"))

    resize(390, 844)
    assert_selector "[data-testid=rendered-file]"
    save_screenshot(SCREENSHOTS.join("file_view_390.png"))
    assert_operator horizontal_overflow, :<=, 1, "the file view scrolls sideways at 390px"
  end

  test "a wide table scrolls inside its own block rather than the page" do
    open_file
    resize(390, 844)

    assert_selector "[data-testid=rendered-file] table"
    assert_operator horizontal_overflow, :<=, 1
  end

  test "the switcher jumps on the page instead of navigating, so it costs nothing" do
    open_file

    find("[data-testid=file-switcher] summary").click
    assert_selector "[data-testid=file-switcher-item]", minimum: 2

    # Every file is already rendered, so a row is a fragment link and hovering
    # or clicking one spends no GitHub call at all — not the three a file view
    # used to cost. `turbo: false` on the row is what keeps that true: a Turbo
    # visit to "#anchor" would re-render the body from the snapshot cache and
    # throw away whatever the page was holding.
    before = github_request_count

    row = find("[data-testid=file-switcher-item]", text: "changelog.md", match: :first)
    assert_equal "false", row["data-turbo"]
    row.hover
    sleep 0.5
    row.click

    assert_selector "[data-testid=file-switcher] summary", text: "changelog.md", wait: 5
    assert_equal before, github_request_count,
                 "jumping to another file must not cost a GitHub request"
  end

  test "on a phone the block keeps its + and the per-child ones step aside" do
    open_file
    resize(390, 844)

    # DESIGN §7: the "+" cannot live in a 0.75rem gutter and there is no hover
    # on touch, so the block's own affordance moves inline and stays visible.
    assert_selector "[data-testid=md-block] > .md-gutter > .md-add", visible: true, minimum: 3

    # A second, nested affordance has nowhere to go at this width without
    # covering an ordered list's numbers, so a reviewer comments on the list.
    assert_no_selector ".md-add--child", visible: true
    assert_no_selector ".md-add--row", visible: true
    assert_selector ".md-add--child", visible: :all, minimum: 3
  end

  private

  def horizontal_overflow
    page.evaluate_script(
      "document.documentElement.scrollWidth - document.documentElement.clientWidth"
    )
  end

  def resize(width, height)
    page.driver.browser.manage.window.resize_to(width, height)
  end

  # The Markdown tab holds every file in the pull request, so this returns
  # docs/deploy.md's own section: everything this test class asserts is about
  # that one document, and a page-wide `all(...)` would be counting the second
  # file too.
  def open_file
    sign_in_as(@user)
    visit repo_pull_markdown_path(owner: OWNER, repo: REPO, number: NUMBER,
                                  anchor: Review::Page.file_key(PATH))
    assert_selector "[data-testid=rendered-file]", minimum: 1
    section
  end

  def section = find("##{Review::Page.file_key(PATH)}")

  # Selenium's own WebDriver traffic goes through WebMock's registry too, so
  # count only what actually went to GitHub.
  def github_request_count
    WebMock::RequestRegistry.instance.requested_signatures.hash
                            .select { |signature, _| signature.uri.host == "api.github.com" }
                            .values.sum
  end

  def opacity(node)
    page.evaluate_script("getComputedStyle(arguments[0]).opacity", node)
  end

  def files_json
    [
      file_json(PATH, status: "modified", patch: PATCH),
      file_json("docs/changelog.md", status: "added",
                patch: "@@ -0,0 +1,3 @@\n+# Changelog\n+\n+Nothing yet.")
    ]
  end

  def file_json(path, status:, patch:)
    { "filename" => path, "status" => status, "additions" => 5, "deletions" => 2,
      "changes" => 7, "patch" => patch,
      "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{path}" }
  end

  # One live thread on the alert this pull request added, so the screen shows a
  # comment where a reviewer would leave one.
  def threads_response
    {
      repository: { pullRequest: {
        id: "PR_kwDOABCD12MAAAABc9Vk",
        reviewThreads: {
          pageInfo: { hasNextPage: false, endCursor: nil },
          nodes: [ {
            id: "PRRT_deploy_1", path: PATH, line: 5, originalLine: 5,
            startLine: nil, originalStartLine: nil, diffSide: "RIGHT",
            startDiffSide: nil, subjectType: "LINE", isResolved: false,
            isOutdated: false, viewerCanResolve: true, viewerCanUnresolve: false,
            viewerCanReply: true, resolvedBy: nil,
            comments: { pageInfo: { hasNextPage: false, endCursor: nil }, nodes: [ {
              id: "PRRC_deploy_1", databaseId: 910001,
              body: "Worth saying which build — the merge queue one?",
              bodyHTML: "<p>Worth saying which build — the merge queue one?</p>",
              state: "SUBMITTED", createdAt: "2026-09-18T09:00:00Z",
              url: "https://github.com/#{OWNER}/#{REPO}/pull/#{NUMBER}#discussion_r910001",
              diffHunk: "@@ -1,8 +1,9 @@\n+> [!NOTE]", outdated: false,
              viewerCanUpdate: false, viewerCanDelete: false, viewerCanReact: true,
              author: { login: "octocat", avatarUrl: "https://avatars.githubusercontent.com/u/583231?v=4",
                        url: "https://github.com/octocat" },
              replyTo: nil, reactionGroups: []
            } ] }
          } ]
        }
      } }
    }
  end

  def stub_contents(path, ref, body)
    stub_github_raw_get("/repos/#{OWNER}/#{REPO}/contents/#{path}",
                        body: body, query: hash_including({ "ref" => ref }))
  end
end
