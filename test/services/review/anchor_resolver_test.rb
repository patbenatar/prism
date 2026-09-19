# frozen_string_literal: true

require "test_helper"

module Review
  class AnchorResolverTest < ActiveSupport::TestCase
    PATH = "README.md"

    # A stand-in for a rendered block: the resolver only reads its line range.
    def block(start_line, end_line = start_line)
      Markdown::Block.new(id: "b", type: :paragraph, start_line: start_line,
                          end_line: end_line, html: "", plain_text: "",
                          depth: 0, parent_id: nil, children: [])
    end

    def sets(patch) = Diff::Patch.parse(patch)

    # --- the rule table -----------------------------------------------------

    test "a contiguous run of two or more becomes a multi-line anchor" do
      anchor = AnchorResolver.call(block(1, 3), sets("@@ -1,3 +1,3 @@\n+a\n+b\n+c\n"), path: PATH)

      assert_predicate anchor, :multi_line?
      assert_equal 1, anchor.start_line
      assert_equal 3, anchor.line
      assert_equal :right, anchor.side
    end

    test "a single in-diff line becomes a single-line anchor" do
      anchor = AnchorResolver.call(block(1, 3), sets("@@ -2,1 +2,1 @@\n+b\n"), path: PATH)

      assert_not_predicate anchor, :multi_line?
      assert_equal 2, anchor.line
    end

    test "a partly-changed block anchors to the contiguous in-diff run only" do
      # Block spans 10..18; only 12..14 are in the diff.
      patch = "@@ -12,3 +12,3 @@\n+text 12\n+text 13\n+text 14\n"
      anchor = AnchorResolver.call(block(10, 18), sets(patch), path: PATH)

      assert_equal 12, anchor.start_line
      assert_equal 14, anchor.line
    end

    test "gapped in-diff lines fall back to the first added line" do
      # GitHub cannot express a gapped range, and a spanning anchor would claim
      # lines that are not in the diff.
      patch = "@@ -10,1 +10,1 @@\n+ten\n@@ -14,1 +14,1 @@\n+fourteen\n"
      anchor = AnchorResolver.call(block(10, 18), sets(patch), path: PATH)

      assert_not_predicate anchor, :multi_line?
      assert_equal 10, anchor.line
    end

    test "prefers an added line over surrounding context" do
      patch = "@@ -1,3 +1,3 @@\n ctx one\n+added two\n ctx three\n"
      anchor = AnchorResolver.call(block(1, 3), sets(patch), path: PATH)

      # 1..3 is contiguous, so this is a range; the run covers the added line.
      assert_equal 1, anchor.start_line
      assert_equal 3, anchor.line
    end

    test "with one context line and one added line apart, picks the added one" do
      patch = "@@ -1,1 +1,1 @@\n ctx\n@@ -5,1 +5,1 @@\n+added\n"
      anchor = AnchorResolver.call(block(1, 6), sets(patch), path: PATH)

      assert_equal 5, anchor.line
    end

    test "a context-only block is still commentable" do
      patch = "@@ -1,2 +1,2 @@\n ctx one\n ctx two\n"
      anchor = AnchorResolver.call(block(1, 2), sets(patch), path: PATH)

      assert_instance_of Anchor, anchor
      assert_equal 1, anchor.start_line
    end

    # --- not commentable ----------------------------------------------------

    test "a block with no line in the diff is not commentable" do
      result = AnchorResolver.call(block(50, 60), sets("@@ -1,1 +1,1 @@\n+a\n"), path: PATH)

      assert_instance_of NotCommentable, result
      assert_equal :outside_diff, result.reason
      assert_not_predicate result, :commentable?
    end

    test "no patch at all reports a distinct reason" do
      result = AnchorResolver.call(block(1, 2), Diff::LineSets.empty, path: PATH)

      assert_equal :no_patch, result.reason
    end

    test "every reason has an explanation for the composer" do
      NotCommentable::REASONS.each do |reason|
        assert_not_empty NotCommentable.new(reason: reason).explanation
      end
    end

    test "rejects an unknown reason" do
      assert_raises(ArgumentError) { NotCommentable.new(reason: :whatever) }
    end

    # --- the left side ------------------------------------------------------

    test "resolving on the left side uses base-side lines" do
      patch = "@@ -1,3 +0,0 @@\n-one\n-two\n-three\n"
      anchor = AnchorResolver.call(block(1, 3), sets(patch), path: PATH, side: :left)

      assert_equal :left, anchor.side
      assert_equal 1, anchor.start_line
      assert_equal 3, anchor.line
    end

    test "a right-side block is not commentable on the left when nothing was removed" do
      result = AnchorResolver.call(block(1, 2), sets("@@ -0,0 +1,2 @@\n+a\n+b\n"),
                                   path: PATH, side: :left)

      assert_equal :outside_diff, result.reason
    end

    test "the anchor carries the path it was asked for" do
      anchor = AnchorResolver.call(block(1), sets("@@ -1,1 +1,1 @@\n+a\n"), path: "docs/x.md")

      assert_equal "docs/x.md", anchor.path
    end
  end
end
