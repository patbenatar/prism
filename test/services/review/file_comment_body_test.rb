# frozen_string_literal: true

require "test_helper"

module Review
  class FileCommentBodyTest < ActiveSupport::TestCase
    def block(text, start_line: 4, end_line: 6)
      Markdown::Block.new(id: "b", type: :paragraph, start_line: start_line,
                          end_line: end_line, html: "", plain_text: text,
                          depth: 0, parent_id: nil, children: [])
    end

    def body_for(block, body: "My comment.")
      FileCommentBody.call(block: block, owner: "acme", repo: "docs",
                           head_sha: "abc123", path: "guide.md", body: body)
    end

    test "quotes the block, links to it, then carries the comment" do
      result = body_for(block("The original text."))

      assert_includes result, "> The original text."
      assert_includes result, "https://github.com/acme/docs/blob/abc123/guide.md#L4-L6"
      assert_includes result, "My comment."
      assert_operator result.index("> The original"), :<, result.index("My comment.")
    end

    test "a single-line block links to one line" do
      result = body_for(block("One liner.", start_line: 9, end_line: 9))

      assert_includes result, "guide.md#L9"
      assert_not_includes result, "#L9-L9"
    end

    test "every line of a multi-line quote is prefixed" do
      result = body_for(block("first\nsecond"))

      assert_includes result, "> first"
      assert_includes result, "> second"
    end

    test "a long block is truncated so the quote stays readable" do
      result = body_for(block("x" * 500))

      assert_includes result, "…"
      assert_operator result.lines.first.length, :<, 340
    end

    test "a short block is not truncated" do
      result = body_for(block("short"))

      assert_not_includes result, "…"
    end

    test "an empty block still produces a usable quote" do
      result = body_for(block(""))

      assert_includes result, "_(empty block)_"
      assert_includes result, "My comment."
    end

    test "the comment body is trimmed" do
      result = body_for(block("text"), body: "  spaced  \n")

      assert result.end_with?("spaced")
    end

    test "permalink can be built on its own" do
      link = FileCommentBody.permalink(owner: "a", repo: "b", head_sha: "sha",
                                       path: "d/e.md", block: block("x", start_line: 1, end_line: 2))

      assert_equal "https://github.com/a/b/blob/sha/d/e.md#L1-L2", link
    end
  end
end
