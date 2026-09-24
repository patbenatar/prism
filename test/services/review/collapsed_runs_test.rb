# frozen_string_literal: true

require "test_helper"

# Which stretches of a file fold away, and — the rule with no exceptions —
# which never do.
class Review::CollapsedRunsTest < ActiveSupport::TestCase
  # A document written as a string: "." is unchanged, "+" added, "~" modified.
  # Reads as the shape of a diff, which is what these tests are about.
  def document(shape, threads_on: [], removed_before_on: [])
    shape.chars.each_with_index.map do |mark, index|
      annotated(index,
                change: { "+" => :added, "~" => :modified }.fetch(mark, :unchanged),
                threads: threads_on.include?(index) ? [ :a_thread ] : [],
                removed_before: removed_before_on.include?(index) ? [ :a_block ] : [])
    end
  end

  def annotated(index, change:, threads: [], removed_before: [], children: [])
    Review::AnnotatedBlock.new(
      block: Markdown::Block.new(id: "b#{index}", type: :paragraph, start_line: index + 1,
                                 end_line: index + 1, html: "<p>#{index}</p>", plain_text: index.to_s,
                                 depth: 0, parent_id: nil, children: []),
      change: change, commentable: true, uncommentable_reason: nil, anchor: nil,
      threads: threads, removed_before: removed_before, children: children
    )
  end

  # The shape the segments come out as: "[…]" is folded away, bare is shown.
  def shape_of(segments)
    segments.map { |segment| segment.collapsed? ? "[#{segment.size}]" : segment.size.to_s }.join(" ")
  end

  def call(shape, **options) = Review::CollapsedRuns.call(document(shape, **options))

  def folded_ids(segments)
    segments.select(&:collapsed?).flat_map(&:blocks).map { |block| block.block.id }
  end

  # ------------------------------------------------------------- the rules --

  test "a changed block keeps two blocks of context either side" do
    # Twenty blocks, one change at index 10. Blocks 8-12 stay — the change and
    # two either side — and the long runs before and after fold away.
    assert_equal "[8] 5 [7]", shape_of(call("#{"." * 10}+#{"." * 9}"))
  end

  test "a gap too short to be worth an expander stays open" do
    # Two changes six apart. Two blocks of context each leaves a single block
    # between them, and one block is not worth a control and a click.
    assert_equal "11", shape_of(call("..+.....+.."))
  end

  test "a gap of exactly the minimum folds" do
    gap = "." * (Review::CollapsedRuns::MINIMUM + Review::CollapsedRuns::CONTEXT * 2)

    assert_equal "3 [3] 3", shape_of(call("+#{gap}+"))
  end

  # -------------------------------------------------- what never folds away --

  test "a block carrying a thread is never folded away" do
    # Block 8 sits deep inside a run that would otherwise fold whole. It holds
    # itself open and splits the run in two around it.
    segments = call("+#{"." * 11}", threads_on: [ 8 ])

    assert_not_includes folded_ids(segments), "b8", "a hidden comment is a lost comment"
    assert_includes folded_ids(segments), "b7", "its neighbours still fold"
    assert_includes folded_ids(segments), "b9"
  end

  test "a thread on a list item holds its parent block open too" do
    # The thread is on a child, not on the block itself — which is where a
    # comment on one bullet or one table row lives.
    blocks = document("+...........")
    blocks[8] = annotated(8, change: :unchanged,
                             children: [ annotated(99, change: :unchanged, threads: [ :a_thread ]) ])

    assert_not_includes folded_ids(Review::CollapsedRuns.call(blocks)), "b8"
  end

  test "a block with content deleted just before it is never folded away" do
    # The removed strip renders above that block and is the only place those
    # deleted lines appear on the page.
    segments = call("+...........", removed_before_on: [ 8 ])

    assert_not_includes folded_ids(segments), "b8"
  end

  test "a changed block that also carries a removed strip still keeps its context" do
    # The common case for an edited line, and the one that caught this: the
    # block that replaced a line is changed *and* pinned, because the line it
    # replaced renders as a removed strip above it. Being pinned must not cost
    # it the context every other change gets.
    segments = Review::CollapsedRuns.call(document("#{"." * 10}~#{"." * 9}", removed_before_on: [ 10 ]))

    assert_equal "[8] 5 [7]", shape_of(segments)
  end

  # --------------------------------------------------- files that fold none --

  test "an added file has no unchanged parts, so nothing folds" do
    segments = call("++++++++++")

    assert_equal 1, segments.size
    assert_not segments.first.collapsed?
    assert_equal 10, segments.first.size
  end

  test "a file with nothing changed at all is shown whole" do
    # A pure rename, or a diff GitHub withheld. The reviewer opened it to read
    # it; folding every unchanged block would fold the entire document.
    segments = call("..............")

    assert_equal 1, segments.size
    assert_not segments.first.collapsed?
    assert_equal 14, segments.first.size
  end

  test "a file the pull request deletes is shown whole" do
    # Every block reads as removed on this screen whatever the mapper called
    # it, and it is the thing being deleted — there is nothing to fold away.
    segments = Review::CollapsedRuns.call(document(".........."), removed_file: true)

    assert_equal 1, segments.size
    assert_not segments.first.collapsed?
  end

  test "an empty document produces no segments" do
    assert_equal [], Review::CollapsedRuns.call([])
  end

  # ------------------------------------------------------------ invariants --

  test "the segments hold every block exactly once, in order" do
    blocks = document("..+.........~....", threads_on: [ 9 ])
    segments = Review::CollapsedRuns.call(blocks)

    assert_equal blocks.map { |block| block.block.id },
                 segments.flat_map(&:blocks).map { |block| block.block.id }
  end

  test "no changed block is ever inside a folded run" do
    segments = Review::CollapsedRuns.call(document("..+.........~...........+.."))

    folded = segments.select(&:collapsed?).flat_map(&:blocks)

    assert folded.any?, "this shape should fold something"
    assert folded.none?(&:changed?)
  end
end
