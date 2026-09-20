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

  private

  def key_for(text, user_id)
    [ "markdown-blocks", user_id, Digest::SHA256.hexdigest(text) ]
  end
end
