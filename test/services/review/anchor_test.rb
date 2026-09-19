# frozen_string_literal: true

require "test_helper"

module Review
  class AnchorTest < ActiveSupport::TestCase
    test "a single-line anchor serializes to both wire shapes" do
      anchor = Anchor.line(path: "README.md", line: 12)

      assert_equal({ path: "README.md", line: 12, side: "RIGHT", subject_type: "line" },
                   anchor.to_rest)
      assert_equal({ path: "README.md", line: 12, side: "RIGHT", subjectType: "LINE" },
                   anchor.to_graphql)
    end

    test "a multi-line anchor carries both ends and both sides" do
      anchor = Anchor.multi_line(path: "a.md", start_line: 7, line: 9)

      assert_predicate anchor, :multi_line?
      assert_equal({ path: "a.md", line: 9, side: "RIGHT", start_line: 7,
                     start_side: "RIGHT", subject_type: "line" }, anchor.to_rest)
      assert_equal({ path: "a.md", line: 9, side: "RIGHT", startLine: 7,
                     startSide: "RIGHT", subjectType: "LINE" }, anchor.to_graphql)
    end

    test "a file anchor carries no line or side" do
      anchor = Anchor.file("docs/x.md")

      assert_predicate anchor, :file?
      assert_equal({ path: "docs/x.md", subject_type: "file" }, anchor.to_rest)
      assert_equal({ path: "docs/x.md", subjectType: "FILE" }, anchor.to_graphql)
    end

    test "nil values are omitted rather than serialized as null" do
      # GitHub rejects an explicit null start_line.
      assert_not_includes Anchor.line(path: "a.md", line: 1).to_rest.keys, :start_line
      assert_not_includes Anchor.line(path: "a.md", line: 1).to_graphql.keys, :startLine
    end

    test "a LEFT anchor serializes its side" do
      anchor = Anchor.line(path: "a.md", line: 4, side: :left)

      assert_equal "LEFT", anchor.to_rest[:side]
      assert_equal "LEFT", anchor.to_graphql[:side]
    end

    test "start_side defaults to side but can differ" do
      assert_equal "LEFT", Anchor.multi_line(path: "a.md", start_line: 1, line: 3,
                                             side: :left).to_rest[:start_side]

      # side and start_side are documented independently; a mixed range is
      # expressible, so nothing here may assume they match.
      mixed = Anchor.multi_line(path: "a.md", start_line: 1, line: 3,
                                side: :right, start_side: :left)

      assert_equal "RIGHT", mixed.to_rest[:side]
      assert_equal "LEFT", mixed.to_rest[:start_side]
    end

    test "to_review_comment omits subject_type, which that endpoint rejects" do
      # POST /pulls/{n}/reviews accepts only path, body, line, side, start_line,
      # start_side and position inside its comments array.
      payload = Anchor.line(path: "a.md", line: 3).to_review_comment

      assert_equal({ path: "a.md", line: 3, side: "RIGHT" }, payload)
      assert_not_includes payload.keys, :subject_type
    end

    test "to_review_comment carries both ends of a range" do
      payload = Anchor.multi_line(path: "a.md", start_line: 1, line: 3).to_review_comment

      assert_equal({ path: "a.md", line: 3, side: "RIGHT",
                     start_line: 1, start_side: "RIGHT" }, payload)
    end

    test "to_review_comment refuses a file anchor rather than posting it unanchored" do
      assert_raises(ArgumentError) { Anchor.file("a.md").to_review_comment }
    end

    # --- validation ---------------------------------------------------------

    test "rejects a start_line at or after line" do
      assert_raises(ArgumentError) { Anchor.multi_line(path: "a.md", start_line: 5, line: 5) }
      assert_raises(ArgumentError) { Anchor.multi_line(path: "a.md", start_line: 9, line: 5) }
    end

    test "rejects a line anchor with no line" do
      assert_raises(ArgumentError) do
        Anchor.new(path: "a.md", subject_type: :line, side: :right, line: nil,
                   start_side: nil, start_line: nil)
      end
    end

    test "rejects an unknown side or subject type" do
      assert_raises(ArgumentError) { Anchor.line(path: "a.md", line: 1, side: :sideways) }
      assert_raises(ArgumentError) do
        Anchor.new(path: "a.md", subject_type: :paragraph, side: :right, line: 1,
                   start_side: nil, start_line: nil)
      end
    end

    test "rejects a file anchor carrying a line" do
      assert_raises(ArgumentError) do
        Anchor.new(path: "a.md", subject_type: :file, side: nil, line: 3,
                   start_side: nil, start_line: nil)
      end
    end

    test "rejects a blank path" do
      assert_raises(ArgumentError) { Anchor.line(path: "", line: 1) }
    end

    test "rejects start_side without start_line" do
      assert_raises(ArgumentError) do
        Anchor.new(path: "a.md", subject_type: :line, side: :right, line: 3,
                   start_side: :right, start_line: nil)
      end
    end
  end
end
