# frozen_string_literal: true

require "test_helper"

# Where the `<img>` tags in a rendered Markdown file actually point.
#
# The bug this covers is the one a reader sees as a row of broken-image icons:
# a Markdown image is written relative to the *file*, and emitted verbatim the
# browser resolves it against Prism and 404s. These tests assert on the
# rendered page rather than on Review::RepoImages, because the interesting part
# is which ref and which directory each side of each file is measured from —
# and that is decided in Review::Page, three layers up from the rewriter.
class MarkdownImagesTest < ActionDispatch::IntegrationTest
  OWNER = "acme"
  REPO = "docs-site"
  NUMBER = 42
  HEAD_SHA = "6dcb09b5b57875f334f61aebed695e2e4193db5e"
  BASE_SHA = "1c2d3e4f5061728394a5b6c7d8e9f0a1b2c3d4e5"

  # A proposal in a deep subdirectory whose charts sit beside it — the shape
  # that started this, and the one where "relative to the file" and "relative
  # to the page" are furthest apart.
  DEEP = "proposals/platform/webhooks/README.md"
  DEEP_HEAD = <<~MARKDOWN
    # Webhooks

    Deliveries per day:

    ![Deliveries per day](deliveries-daily.png)

    And the shared diagram:

    ![Shared](../shared/architecture.svg)

    A badge from elsewhere:

    ![Build](https://img.shields.io/badge/build-passing.svg)
  MARKDOWN
  DEEP_PATCH = "@@ -0,0 +1,13 @@\n" + DEEP_HEAD.lines.map { |line| "+#{line}" }.join

  # A file this pull request deletes. It renders from BASE, so its images have
  # to resolve at the base sha — they were deleted by the same push.
  GONE = "docs/legacy/old.md"
  GONE_BASE = "# Legacy\n\n![Old chart](chart.png)\n"
  GONE_PATCH = "@@ -1,3 +0,0 @@\n-# Legacy\n-\n-![Old chart](chart.png)\n"

  # Renamed out of one directory into another. The head side's images are
  # relative to the new directory and the base side's to the old one.
  MOVED = "docs/new/install.md"
  MOVED_PREVIOUS = "docs/old/install.md"
  MOVED_HEAD = "# Install\n\n![Step one](step1.png)\n"
  MOVED_BASE = "# Install\n\n![Step one](step1.png)\n\n![Old note](old.png)\n"
  MOVED_PATCH = "@@ -1,5 +1,3 @@\n # Install\n \n ![Step one](step1.png)\n-\n-![Old note](old.png)\n"

  # Byte-for-byte the same document as DEEP, in another directory. The parse is
  # cached on the content digest, so this is the file that catches a cache key
  # that forgot the rewrite depends on more than the bytes.
  TWIN = "docs/copy/README.md"
  TWIN_PATCH = DEEP_PATCH

  setup do
    @user = users(:prism_dev)
    sign_in_as(@user)
    stub_page
  end

  def proxy(path, ref: HEAD_SHA) = repo_raw_path(owner: OWNER, repo: REPO, ref: ref, path: path)

  def image_sources
    get repo_pull_markdown_path(owner: OWNER, repo: REPO, number: NUMBER)
    assert_response :success
    css_select("[data-testid=rendered-file] img").map { |img| img["src"] }
  end

  # --------------------------------------------------------------- the fix ---

  test "a sibling image resolves against the document's directory at the head sha" do
    assert_includes image_sources, proxy("proposals/platform/webhooks/deliveries-daily.png")
  end

  test "a parent-relative image walks up from the document, not from the page" do
    assert_includes image_sources, proxy("proposals/platform/shared/architecture.svg")
  end

  test "no rendered image is left pointing at a path the browser would resolve against Prism" do
    relative = image_sources.reject { |src| src.start_with?("/", "https://", "http://", "data:") }

    assert_empty relative, "these would 404 against throughprism.dev: #{relative.inspect}"
  end

  # --------------------------------------------------------------- the refs ---

  # The awkward one. The file is deleted by this pull request, so it renders
  # from BASE — and so was the picture in it. At the head sha the chart does not
  # exist; at the base sha it does.
  test "a deleted file's images resolve at the base sha, where they still exist" do
    assert_includes image_sources, proxy("docs/legacy/chart.png", ref: BASE_SHA)
    assert_not_includes image_sources, proxy("docs/legacy/chart.png")
  end

  # A rename moves the directory every relative path in the file is measured
  # from, and the two sides of the diff disagree about which one it is.
  test "a renamed file measures each side from its own directory" do
    sources = image_sources

    assert_includes sources, proxy("docs/new/step1.png")
    assert_includes sources, proxy("docs/old/old.png", ref: BASE_SHA),
                    "the removed strip renders base-side content at the base path"
  end

  # ------------------------------------------------------- what is left alone ---

  test "an image hosted somewhere else is left exactly as the author wrote it" do
    assert_includes image_sources, "https://img.shields.io/badge/build-passing.svg"
  end

  # GitHub renders comment bodies for us and hands back absolute camo URLs,
  # which already load. Nothing in the image path should touch them.
  test "images in a GitHub-rendered comment body are untouched" do
    camo = "https://camo.githubusercontent.com/abc/def"
    html = %(<p>Look: <img src="#{camo}" alt="screenshot"></p>)

    assert_includes Markdown::Sanitizer.call(html), camo
  end

  # ------------------------------------------------------------- the parse ---

  # Review::ParsedSource caches on the content digest, and the rewrite made the
  # parse depend on more than the content. The same bytes in two directories
  # must not come back with each other's image URLs.
  test "two files with identical bytes in different directories get their own images" do
    with_memory_cache do
      sources = image_sources

      assert_includes sources, proxy("proposals/platform/webhooks/deliveries-daily.png")
      assert_includes sources, proxy("docs/copy/deliveries-daily.png")
    end
  end

  private

  def stub_page
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}", fixture: :pull)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/files", body: files)
    stub_github_get("/repos/#{OWNER}/#{REPO}/pulls/#{NUMBER}/reviews", body: [])
    stub_github_graphql(:ReviewThreads,
                        data: { repository: { pullRequest: { id: "PR_1", reviewThreads: {
                          pageInfo: { hasNextPage: false, endCursor: nil }, nodes: []
                        } } } })

    stub_contents(DEEP, HEAD_SHA, DEEP_HEAD)
    stub_contents(GONE, BASE_SHA, GONE_BASE)
    stub_contents(MOVED, HEAD_SHA, MOVED_HEAD)
    stub_contents(MOVED_PREVIOUS, BASE_SHA, MOVED_BASE)
    stub_contents(TWIN, HEAD_SHA, DEEP_HEAD)
  end

  def stub_contents(path, ref, body)
    stub_github_raw_get("/repos/#{OWNER}/#{REPO}/contents/#{path}",
                        body: body, query: hash_including({ "ref" => ref }))
  end

  def files
    [
      file(DEEP, status: "added", patch: DEEP_PATCH),
      file(GONE, status: "removed", patch: GONE_PATCH),
      file(MOVED, status: "renamed", patch: MOVED_PATCH, previous_filename: MOVED_PREVIOUS),
      file(TWIN, status: "added", patch: TWIN_PATCH)
    ].to_json
  end

  def file(path, status:, patch:, **extra)
    { filename: path, status: status, patch: patch, additions: 1, deletions: 0, changes: 1,
      sha: Digest::SHA1.hexdigest(path),
      blob_url: "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{path}" }.merge(extra)
  end
end
