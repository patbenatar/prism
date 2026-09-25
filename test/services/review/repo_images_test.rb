# frozen_string_literal: true

require "test_helper"

# What an image URL in a Markdown file means. This is the security-bearing half
# of the image fix: everything Prism will ever fetch on a reader's behalf comes
# out of this class, so the tests below are as much about what it *refuses* to
# rewrite as about what it does.
class Review::RepoImagesTest < ActiveSupport::TestCase
  OWNER = "acme"
  REPO = "docs-site"
  SHA = "6dcb09b5b57875f334f61aebed695e2e4193db5e"
  OTHER_SHA = "1c2d3e4f5061728394a5b6c7d8e9f0a1b2c3d4e5"
  DOC = "proposals/platform/webhooks/README.md"

  def images(owner: OWNER, repo: REPO, ref: SHA, dir: DOC)
    Review::RepoImages.new(owner: owner, repo: repo, ref: ref, dir: dir)
  end

  # The path part of the proxy URL, so assertions read as repository paths
  # rather than as whole URLs.
  def resolved(src, **options)
    url = images(**options).call(src)
    url&.delete_prefix("/#{OWNER}/#{REPO}/raw/#{SHA}/")
  end

  # ------------------------------------------------------------- relative ---

  test "a sibling image resolves against the document's directory" do
    assert_equal "proposals/platform/webhooks/chart.png", resolved("chart.png")
  end

  test "an explicitly relative path is the same thing" do
    assert_equal "proposals/platform/webhooks/img/a.png", resolved("./img/a.png")
  end

  test "a parent path walks up one directory" do
    assert_equal "proposals/platform/shared/b.png", resolved("../shared/b.png")
  end

  test "a leading slash means the repository root, not the web root" do
    assert_equal "docs/root.png", resolved("/docs/root.png")
  end

  test "a document at the repository root resolves against the root" do
    assert_equal "logo.png", resolved("logo.png", dir: "README.md")
  end

  test "a query string and a fragment are not part of the path" do
    assert_equal "proposals/platform/webhooks/chart.png", resolved("chart.png?v=2#top")
  end

  # comrak percent-encodes an image destination on the way out, so the space in
  # `![a](<my chart.png>)` arrives as `%20`. It has to survive the round trip:
  # decoded here so `..` and `/` cannot hide inside it, then re-encoded by the
  # route helper, and recognised back as a space when the request arrives.
  test "percent escapes survive the round trip to a repository path" do
    url = images.call("my%20chart.png")

    assert_equal "proposals/platform/webhooks/my%20chart.png",
                 url.delete_prefix("/#{OWNER}/#{REPO}/raw/#{SHA}/")
    assert_equal "proposals/platform/webhooks/my chart.png",
                 Rails.application.routes.recognize_path(url)[:path]
  end

  # ------------------------------------------------------------ traversal ---

  test "walking above the repository root clamps to the root" do
    assert_equal "etc/passwd", resolved("../../../../../../etc/passwd")
  end

  test "an encoded parent segment is still a parent segment" do
    # proposals/platform/webhooks, up twice.
    assert_equal "proposals/escape.png", resolved("%2e%2e/%2e%2e/escape.png")
  end

  # The one that matters. `%2f` survives the first split, so a decoded
  # `../../../owner/repo/raw/<sha>/x.png` would reach the browser whole and be
  # resolved *there* — walking out of our path and naming a different
  # repository in our own route. Splitting again after decoding is what stops
  # it, and this asserts the result stays inside the repository being read.
  test "a percent-encoded separator cannot smuggle a traversal into the URL" do
    url = images.call("%2e%2e%2f%2e%2e%2f%2e%2e%2f%2e%2e%2fevil%2frepo%2fraw%2f#{OTHER_SHA}%2fx.png")

    assert url.start_with?("/#{OWNER}/#{REPO}/raw/#{SHA}/"), "escaped the repository: #{url}"
    assert_not_includes url, ".."
    assert_equal "evil/repo/raw/#{OTHER_SHA}/x.png", url.delete_prefix("/#{OWNER}/#{REPO}/raw/#{SHA}/")
  end

  test "no resolved path ever contains a dot segment" do
    [ "a/./b.png", "a/../b.png", "..%2F..%2Fx.png", "./././x.png" ].each do |src|
      assert_not_includes images.call(src).to_s, "/..", src
      assert_not_includes images.call(src).to_s, "/./", src
    end
  end

  # Every one of these names a directory rather than a file. Rewriting them to
  # the directory's own path would turn a broken link into a URL that quietly
  # means something else.
  test "a path that names a directory rather than an image is left alone" do
    [ ".", "./", "..", "../", "a/..", "", "   ", nil ].each do |src|
      assert_nil images.call(src), src.inspect
    end
  end

  # ------------------------------------------------------------- absolute ---

  test "another site's image is left exactly as written" do
    assert_nil images.call("https://example.com/x.png")
    assert_nil images.call("http://example.com/x.png")
  end

  test "a data URI is left alone" do
    assert_nil images.call("data:image/png;base64,iVBORw0KGgo=")
  end

  test "a fragment-only src is left alone" do
    assert_nil images.call("#somewhere")
  end

  test "a camo URL inside a comment body is left alone" do
    assert_nil images.call("https://camo.githubusercontent.com/abc123/def456")
  end

  test "a raw.githubusercontent URL for this repository at a sha is proxied" do
    assert_equal "x.png",
                 resolved("https://raw.githubusercontent.com/#{OWNER}/#{REPO}/#{SHA}/x.png")
  end

  test "a github.com blob URL for this repository at a sha is proxied" do
    assert_equal "docs/y.png",
                 resolved("https://github.com/#{OWNER}/#{REPO}/blob/#{SHA}/docs/y.png?raw=true")
  end

  test "a protocol-relative GitHub URL is proxied too" do
    assert_equal "z.png", resolved("//raw.githubusercontent.com/#{OWNER}/#{REPO}/#{SHA}/z.png")
  end

  test "owner and repository match case-insensitively, the way GitHub reads them" do
    assert_equal "x.png",
                 resolved("https://raw.githubusercontent.com/ACME/Docs-Site/#{SHA}/x.png")
  end

  test "another repository's GitHub URL is left alone" do
    assert_nil images.call("https://raw.githubusercontent.com/someone/else/#{SHA}/x.png")
    assert_nil images.call("https://github.com/someone/else/blob/#{SHA}/x.png")
  end

  # A branch name can contain slashes, so `…/blob/feature/logo/x.png` cannot be
  # split into a ref and a path without asking GitHub which branches exist.
  # Leaving it alone is the honest answer; see the class comment.
  test "a GitHub URL on a branch rather than a sha is left alone" do
    assert_nil images.call("https://github.com/#{OWNER}/#{REPO}/blob/main/x.png")
    assert_nil images.call("https://raw.githubusercontent.com/#{OWNER}/#{REPO}/main/x.png")
  end

  test "a GitHub URL that is not a blob is left alone" do
    assert_nil images.call("https://github.com/#{OWNER}/#{REPO}/issues/1")
    assert_nil images.call("https://github.com/#{OWNER}/#{REPO}/tree/#{SHA}/docs")
  end

  test "a malformed URL is left alone rather than raising" do
    assert_nil images.call("https://[not a host]/x.png")
  end

  # ------------------------------------------------------------- usability ---

  test "a ref that is not a commit sha disables rewriting entirely" do
    %w[main v1.0 abc].each do |ref|
      assert_not images(ref: ref).usable?, ref
      assert_nil images(ref: ref).call("chart.png")
    end
  end

  test "a blank ref, owner or repo disables rewriting" do
    assert_not images(ref: "").usable?
    assert_not images(owner: "").usable?
    assert_not images(repo: "").usable?
  end

  test "an uppercase sha is accepted and normalized" do
    assert images(ref: SHA.upcase).usable?
    assert_includes images(ref: SHA.upcase).call("a.png"), SHA
  end

  # ---------------------------------------------------------------- cache ---

  # Review::ParsedSource keys the parse on this, so two files that render
  # differently must not collide and two that render identically must not miss.
  test "the cache key separates directories, refs and repositories" do
    base = images.cache_key

    assert_not_equal base, images(dir: "docs/other/README.md").cache_key
    assert_not_equal base, images(ref: OTHER_SHA).cache_key
    assert_not_equal base, images(repo: "other").cache_key
    assert_equal base, images(dir: "proposals/platform/webhooks/OTHER.md").cache_key
  end
end
