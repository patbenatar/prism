# frozen_string_literal: true

require "test_helper"

# The parse cache. Written against the cache itself rather than a mock of
# Markdown::Document, because what matters is the key — get that wrong and
# either nothing ever hits, or two different documents share an entry.
class Review::ParsedSourceTest < ActiveSupport::TestCase
  SOURCE = "# Title\n\nA paragraph.\n\n- one\n- two\n"

  test "a parsed document is cached under the digest of the bytes that produced it" do
    with_memory_cache do |cache|
      blocks = Review::ParsedSource.blocks(SOURCE, user_id: 1)

      assert blocks.any?
      assert_equal blocks.map(&:id), cache.read(key_for(SOURCE, 1)).map(&:id)
    end
  end

  test "a second read comes from the cache, not from the parser" do
    with_memory_cache do |cache|
      cache.write(key_for(SOURCE, 1), [ :sentinel ])

      assert_equal [ :sentinel ], Review::ParsedSource.blocks(SOURCE, user_id: 1)
    end
  end

  test "the cached HTML comes back still marked safe, so the view does not escape it" do
    with_memory_cache do
      Review::ParsedSource.blocks(SOURCE, user_id: 1)
      cached = Review::ParsedSource.blocks(SOURCE, user_id: 1)

      assert cached.first.html.html_safe?, "a round trip through the cache must not unmark the HTML"
      assert_includes cached.first.html, "<h1"
    end
  end

  test "different bytes are different entries, and two users never share one" do
    with_memory_cache do |cache|
      cache.write(key_for("# A\n", 1), [ :ours ])

      assert_equal [ :ours ], Review::ParsedSource.blocks("# A\n", user_id: 1)
      assert_not_equal [ :ours ], Review::ParsedSource.blocks("# B\n", user_id: 1)
      assert_not_equal [ :ours ], Review::ParsedSource.blocks("# A\n", user_id: 2)
    end
  end

  test "a blank document is neither parsed nor cached" do
    with_memory_cache do |cache|
      assert_equal [], Review::ParsedSource.blocks("", user_id: 1)
      assert_equal [], Review::ParsedSource.blocks(nil, user_id: 1)
      assert_nil cache.read(key_for("", 1))
    end
  end

  # The parse stopped being a pure function of the bytes when image URLs
  # started being rewritten into it: the same README beside `docs/a/chart.png`
  # and beside `docs/b/chart.png` renders to two different documents. Sharing
  # an entry between them would put one file's pictures in another's page.
  test "the directory an image resolves against is part of the key" do
    source = "![chart](chart.png)\n"

    with_memory_cache do
      here = Review::ParsedSource.blocks(source, user_id: 1, images: images("docs/a/README.md"))
      there = Review::ParsedSource.blocks(source, user_id: 1, images: images("docs/b/README.md"))

      assert_includes here.first.html, "/docs/a/chart.png"
      assert_includes there.first.html, "/docs/b/chart.png"
    end
  end

  test "a document parsed without an image resolver keeps its own entry" do
    source = "![chart](chart.png)\n"

    with_memory_cache do |cache|
      Review::ParsedSource.blocks(source, user_id: 1)

      assert cache.read(key_for(source, 1)).present?
      assert_includes cache.read(key_for(source, 1)).first.html, %(src="chart.png")
    end
  end

  # Every id in a document is scoped to its file, so the same bytes at two
  # paths are two documents. Sharing an entry would hand the second file the
  # first one's ids, and with them its section links.
  test "the file an anchor is scoped to is part of the key" do
    source = "# Overview\n"

    with_memory_cache do |cache|
      one = Markdown::Anchors.new(scope: "f-0000000001", path: "a.md")
      two = Markdown::Anchors.new(scope: "f-0000000002", path: "b.md")

      first = Review::ParsedSource.blocks(source, user_id: 1, anchors: one)
      second = Review::ParsedSource.blocks(source, user_id: 1, anchors: two)

      assert_includes first.first.html, 'id="user-content-f-0000000001-overview"'
      assert_includes second.first.html, 'id="user-content-f-0000000002-overview"'
      assert cache.read(key_for(source, 1, nil, one.cache_key)).present?
    end
  end

  private

  def images(path)
    Review::RepoImages.new(owner: "acme", repo: "docs-site", dir: path,
                           ref: "6dcb09b5b57875f334f61aebed695e2e4193db5e")
  end

  # The nil slot is the image resolver's: a document with no repository to
  # resolve against is cached under the same key it always was. The slot after
  # it is the anchors' scope, which is unscoped unless a test says otherwise.
  def key_for(text, user_id, images_key = nil, anchors_key = Markdown::Anchors.new.cache_key)
    [ "markdown-blocks", user_id, images_key, anchors_key, Digest::SHA256.hexdigest(text) ]
  end
end
