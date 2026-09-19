# frozen_string_literal: true

require "test_helper"

module Diff
  class PatchTest < ActiveSupport::TestCase
    test "maps added, removed and context lines to both sides" do
      sets = Patch.parse(<<~PATCH)
        @@ -1,4 +1,5 @@
         context one
        -removed two
        +added two
        +added three
         context four
      PATCH

      assert_equal({ 1 => :context, 2 => :added, 3 => :added, 4 => :context }, sets.right)
      assert_equal({ 1 => :context, 2 => :removed, 3 => :context }, sets.left)
      assert_equal [ 2, 3 ], sets.added_lines
      assert_equal [ 2 ], sets.removed_lines
    end

    test "honours the starting line numbers in the hunk header" do
      sets = Patch.parse("@@ -10,2 +20,2 @@\n context\n+added\n")

      assert_equal({ 20 => :context, 21 => :added }, sets.right)
      assert_equal({ 10 => :context }, sets.left)
    end

    test "accepts hunk headers with the counts omitted" do
      sets = Patch.parse("@@ -3 +3 @@\n-old\n+new\n")

      assert sets.commentable_right?(3)
      assert sets.removed?(3)
    end

    test "counts an empty-string context line as context" do
      # A blank context line arrives as a single space; some producers strip it.
      # If it were skipped, every later line in the hunk would be off by one.
      sets = Patch.parse("@@ -1,3 +1,3 @@\n first\n\n+third\n")

      assert_equal :context, sets.right[1]
      assert_equal :context, sets.right[2]
      assert_equal :added, sets.right[3]
    end

    test "a single-space context line counts as context" do
      sets = Patch.parse("@@ -1,2 +1,2 @@\n \n+second\n")

      assert_equal :context, sets.right[1]
      assert_equal :added, sets.right[2]
    end

    test "the no-newline marker consumes no line on either side" do
      sets = Patch.parse("@@ -1,2 +1,2 @@\n-old\n\\ No newline at end of file\n+new\n")

      assert_equal({ 1 => :added }, sets.right)
      assert_equal({ 1 => :removed }, sets.left)
    end

    test "handles several hunks with a gap between them" do
      sets = Patch.parse(<<~PATCH)
        @@ -1,2 +1,2 @@
        -a
        +b
        @@ -10,2 +10,2 @@
        -c
        +d
      PATCH

      assert_equal [ 1, 10 ], sets.added_lines
      assert_not sets.commentable_right?(5), "a line between hunks must not be commentable"
    end

    test "an added file has every line added and nothing on the left" do
      sets = Patch.parse("@@ -0,0 +1,3 @@\n+one\n+two\n+three\n")

      assert_equal [ 1, 2, 3 ], sets.added_lines
      assert_empty sets.left
      assert_not sets.empty?
    end

    test "a removed file has every line removed and nothing on the right" do
      sets = Patch.parse("@@ -1,3 +0,0 @@\n-one\n-two\n-three\n")

      assert_equal [ 1, 2, 3 ], sets.removed_lines
      assert_empty sets.right
      assert sets.commentable_left?(2)
    end

    test "right_of_left points a deleted line at the head line that replaced it" do
      sets = Patch.parse("@@ -1,3 +1,3 @@\n context\n-removed\n+added\n")

      assert_equal 2, sets.head_line_for_base(2)
      assert_equal 1, sets.head_line_for_base(1)
      assert_nil sets.head_line_for_base(99)
    end

    test "a nil or blank patch yields empty sets" do
      [ nil, "", "   " ].each do |patch|
        sets = Patch.parse(patch)

        assert_predicate sets, :empty?
        assert_not sets.commentable_right?(1)
      end
    end

    test "ignores content before the first hunk header" do
      sets = Patch.parse("garbage line\n@@ -1,1 +1,1 @@\n+only\n")

      assert_equal({ 1 => :added }, sets.right)
    end

    test "line sets are frozen" do
      sets = Patch.parse("@@ -1,1 +1,1 @@\n+x\n")

      assert_predicate sets, :frozen?
      assert_predicate sets.right, :frozen?
    end

    test "an empty LineSets reports empty" do
      assert_predicate LineSets.empty, :empty?
    end
  end
end
