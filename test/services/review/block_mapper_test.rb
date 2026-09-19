# frozen_string_literal: true

require "test_helper"

module Review
  class BlockMapperTest < ActiveSupport::TestCase
    PATH = "README.md"

    SOURCE = <<~MD
      # Title

      Intro paragraph unchanged here.

      ## Changed section

      This paragraph was
      edited across lines.

      - one
      - two
    MD

    # Lines 5..9 are new; 1..3 and 10..11 are context.
    PATCH = <<~PATCH
      @@ -1,6 +1,11 @@
       # Title
      #{" "}
       Intro paragraph unchanged here.
      #{" "}
      +## Changed section
      +
      +This paragraph was
      +edited across lines.
      +
       - one
       - two
    PATCH

    def head_blocks(source = SOURCE) = Markdown::Document.parse(source).blocks

    def thread(line:, side: "RIGHT", subject_type: "LINE", outdated: false)
      Github::Types::ReviewThread.new(
        node_id: "T#{line}#{side}", path: PATH, line: line, original_line: line,
        start_line: nil, original_start_line: nil, diff_side: side,
        start_diff_side: nil, subject_type: subject_type, is_resolved: false,
        is_outdated: outdated, resolved_by: nil, viewer_can_resolve: true,
        viewer_can_unresolve: false, viewer_can_reply: true, comments: []
      )
    end

    def map(threads: [], patch: PATCH, base_blocks: [], file_status: "modified", source: SOURCE)
      BlockMapper.call(head_blocks: head_blocks(source), base_blocks: base_blocks,
                       line_sets: Diff::Patch.parse(patch), threads: threads,
                       path: PATH, file_status: file_status)
    end

    def block_at(result, line)
      result.blocks.find { |annotated| annotated.block.covers?(line) }
    end

    # --- change classification ---------------------------------------------

    test "blocks containing added lines are marked added" do
      result = map

      assert_equal :added, block_at(result, 5).change
      assert_equal :added, block_at(result, 7).change
    end

    test "unchanged context blocks are marked unchanged" do
      result = map

      assert_equal :unchanged, block_at(result, 1).change
      assert_equal :unchanged, block_at(result, 3).change
    end

    test "a block that lost lines is marked modified" do
      # One line deleted in front of head line 3, which the paragraph covers.
      patch = "@@ -1,4 +1,3 @@\n # Title\n \n-gone\n para\n"
      source = "# Title\n\npara\n"
      result = map(patch: patch, source: source)

      assert_equal :modified, block_at(result, 3).change
    end

    test "added wins over modified when a block both gained and lost lines" do
      patch = "@@ -1,2 +1,2 @@\n-old\n+new\n"
      result = map(patch: patch, source: "new\n")

      assert_equal :added, block_at(result, 1).change
    end

    # --- commentability -----------------------------------------------------

    test "blocks in the diff are commentable and carry an anchor" do
      annotated = block_at(map, 7)

      assert_predicate annotated, :commentable?
      assert_instance_of Anchor, annotated.anchor
      assert_nil annotated.uncommentable_reason
    end

    test "a block outside every hunk is not commentable and says why" do
      # Only line 1 is in the diff; everything else is outside it.
      result = map(patch: "@@ -1,1 +1,1 @@\n # Title\n")
      annotated = block_at(result, 7)

      assert_not_predicate annotated, :commentable?
      assert_nil annotated.anchor
      assert_equal :outside_diff, annotated.uncommentable_reason
    end

    test "with no patch nothing is commentable and the reason distinguishes it" do
      result = map(patch: nil)

      assert_empty result.blocks.select(&:commentable?)
      assert_equal [ :no_patch ], result.blocks.map(&:uncommentable_reason).uniq
    end

    test "children are annotated too, so a single list item can be commented on" do
      list = block_at(map, 10)

      assert_equal 2, list.children.size
      assert_predicate list.children.first, :commentable?
      assert_equal 10, list.children.first.anchor.line
    end

    # --- thread placement ---------------------------------------------------

    test "a RIGHT thread attaches to the deepest block covering its line" do
      result = map(threads: [ thread(line: 10) ])
      list = block_at(result, 10)

      assert_empty list.threads, "the thread belongs on the item, not the whole list"
      assert_equal 1, list.children.first.threads.size
    end

    test "a RIGHT thread on a paragraph attaches to that paragraph" do
      result = map(threads: [ thread(line: 7) ])

      assert_equal 1, block_at(result, 7).threads.size
    end

    test "an outdated thread goes to the outdated bucket, never a block" do
      result = map(threads: [ thread(line: 7, outdated: true) ])

      assert_equal 1, result.outdated_threads.size
      assert_empty result.all_blocks.flat_map(&:threads)
    end

    test "a thread with a null line is treated as outdated" do
      result = map(threads: [ thread(line: nil) ])

      assert_equal 1, result.outdated_threads.size
    end

    test "a file-level thread goes to the file bucket" do
      result = map(threads: [ thread(line: nil, subject_type: "FILE") ])

      assert_equal 1, result.file_threads.size
      assert_empty result.outdated_threads
    end

    test "a LEFT thread is placed through right_of_left onto the head block" do
      # Base line 3 was deleted; head line 3 now sits there.
      patch = "@@ -1,4 +1,3 @@\n # Title\n \n-gone\n para\n"
      result = BlockMapper.call(
        head_blocks: head_blocks("# Title\n\npara\n"), base_blocks: [],
        line_sets: Diff::Patch.parse(patch), threads: [ thread(line: 3, side: "LEFT") ],
        path: PATH, file_status: "modified"
      )

      assert_equal 1, block_at(result, 3).threads.size
      assert_empty result.unplaced_threads
    end

    test "a thread on a line no block covers is reported rather than dropped" do
      result = map(threads: [ thread(line: 999) ])

      assert_equal 1, result.unplaced_threads.size
      assert_empty result.all_blocks.flat_map(&:threads)
    end

    # --- removed strips -----------------------------------------------------

    test "base blocks deleted entirely appear as a strip before the head block" do
      base = Markdown::Document.parse("# Title\n\nold paragraph\n\nkept\n").blocks
      patch = "@@ -1,5 +1,3 @@\n # Title\n \n-old paragraph\n-\n kept\n"
      result = BlockMapper.call(
        head_blocks: Markdown::Document.parse("# Title\n\nkept\n").blocks,
        base_blocks: base, line_sets: Diff::Patch.parse(patch), threads: [],
        path: PATH, file_status: "modified"
      )

      strips = result.blocks.flat_map(&:removed_before)

      assert_equal 1, strips.size
      assert_equal "old paragraph", strips.first.plain_text
    end

    test "a block with a mix of deleted and kept lines is not a removed strip" do
      base = Markdown::Document.parse("one\ntwo\n").blocks
      patch = "@@ -1,2 +1,1 @@\n one\n-two\n"
      result = BlockMapper.call(
        head_blocks: Markdown::Document.parse("one\n").blocks, base_blocks: base,
        line_sets: Diff::Patch.parse(patch), threads: [], path: PATH
      )

      assert_empty result.blocks.flat_map(&:removed_before)
    end

    test "content deleted from the end of a file surfaces as trailing_removed" do
      # It maps to a head line past every head block, so it has nothing to sit
      # before. Dropping it would tell the reviewer the content is still there.
      base = Markdown::Document.parse("kept\n\ngone\n").blocks
      patch = "@@ -1,3 +1,1 @@\n kept\n-\n-gone\n"
      result = BlockMapper.call(
        head_blocks: Markdown::Document.parse("kept\n").blocks, base_blocks: base,
        line_sets: Diff::Patch.parse(patch), threads: [], path: PATH
      )

      assert_empty result.blocks.flat_map(&:removed_before)
      assert_equal [ "gone" ], result.trailing_removed.map(&:plain_text)
    end

    test "content deleted mid-file goes before a block, not to trailing_removed" do
      base = Markdown::Document.parse("gone\n\nkept\n").blocks
      patch = "@@ -1,3 +1,1 @@\n-gone\n-\n kept\n"
      result = BlockMapper.call(
        head_blocks: Markdown::Document.parse("kept\n").blocks, base_blocks: base,
        line_sets: Diff::Patch.parse(patch), threads: [], path: PATH
      )

      assert_equal [ "gone" ], result.blocks.flat_map(&:removed_before).map(&:plain_text)
      assert_empty result.trailing_removed
    end

    test "trailing_removed is empty when nothing was deleted" do
      assert_empty map.trailing_removed
    end

    test "a strip attaches to the head block covering its mapped line, not only one starting there" do
      # Deleting the blank lines around "gone" joins "a" and "b" into a single
      # head paragraph spanning lines 1..2, and the deletion maps to head line 2
      # — inside that block, not at its start. Matching only on start_line would
      # find nothing here and lose the strip.
      base = Markdown::Document.parse("a\n\ngone\n\nb\n").blocks
      patch = "@@ -1,5 +1,2 @@\n a\n-\n-gone\n-\n b\n"
      head = Markdown::Document.parse("a\nb\n").blocks

      assert_equal [ 1..2 ], head.map(&:range), "the head paragraph must span both lines"

      result = BlockMapper.call(head_blocks: head, base_blocks: base,
                                line_sets: Diff::Patch.parse(patch), threads: [], path: PATH)
      host = result.blocks.find { |annotated| annotated.removed_before.any? }

      assert host, "the strip was dropped instead of attaching to the covering block"
      assert_equal 1..2, host.block.range
      assert_equal [ "gone" ], host.removed_before.map(&:plain_text)
      assert_empty result.trailing_removed
    end

    test "a strip whose mapped line falls between blocks sits before the next one" do
      base = Markdown::Document.parse("one\ntwo\n\ngone\n\nlast\n").blocks
      patch = "@@ -1,6 +1,4 @@\n one\n two\n-\n-gone\n \n last\n"
      head = Markdown::Document.parse("one\ntwo\n\nlast\n").blocks
      result = BlockMapper.call(head_blocks: head, base_blocks: base,
                                line_sets: Diff::Patch.parse(patch), threads: [], path: PATH)
      host = result.blocks.find { |annotated| annotated.removed_before.any? }

      assert_equal 4..4, host.block.range, "it belongs before the block that follows the gap"
      assert_equal [ "gone" ], host.removed_before.map(&:plain_text)
    end

    test "a LEFT thread on a deleted block goes to that strip, not to a head block" do
      base = Markdown::Document.parse("kept\n\ngone\n").blocks
      patch = "@@ -1,3 +1,1 @@\n kept\n-\n-gone\n"
      result = BlockMapper.call(
        head_blocks: Markdown::Document.parse("kept\n").blocks, base_blocks: base,
        line_sets: Diff::Patch.parse(patch),
        threads: [ thread(line: 3, side: "LEFT") ], path: PATH
      )
      strip = result.trailing_removed.first

      assert_equal 1, result.threads_for_strip(strip).size
      assert_empty result.unplaced_threads
      assert_empty result.all_blocks.flat_map(&:threads)
    end

    test "a LEFT thread on a line that still exists stays on the head block" do
      # Base line 2 was deleted, but its paragraph kept lines 1 and 3, so there
      # is no strip and the thread belongs beside the surviving block.
      base = Markdown::Document.parse("one\ntwo\nthree\n").blocks
      patch = "@@ -1,3 +1,2 @@\n one\n-two\n three\n"
      result = BlockMapper.call(
        head_blocks: Markdown::Document.parse("one\nthree\n").blocks, base_blocks: base,
        line_sets: Diff::Patch.parse(patch),
        threads: [ thread(line: 2, side: "LEFT") ], path: PATH
      )

      assert_empty result.removed_strips
      assert_equal 1, result.all_blocks.sum { |annotated| annotated.threads.size }
    end

    test "removed_strips exposes both kinds of strip together" do
      base = Markdown::Document.parse("gone\n\nkept\n").blocks
      patch = "@@ -1,3 +1,1 @@\n-gone\n-\n kept\n"
      result = BlockMapper.call(
        head_blocks: Markdown::Document.parse("kept\n").blocks, base_blocks: base,
        line_sets: Diff::Patch.parse(patch), threads: [], path: PATH
      )

      assert_equal [ "gone" ], result.removed_strips.map(&:plain_text)
    end

    # --- removed files ------------------------------------------------------

    test "a removed file renders the base blocks with LEFT anchors" do
      base = Markdown::Document.parse("# Gone\n\nbody\n").blocks
      result = BlockMapper.call(
        head_blocks: [], base_blocks: base,
        line_sets: Diff::Patch.parse("@@ -1,3 +0,0 @@\n-# Gone\n-\n-body\n"),
        threads: [], path: PATH, file_status: "removed"
      )

      assert_predicate result, :removed_file?
      assert_equal 2, result.blocks.size
      assert_predicate result.blocks.first, :commentable?
      assert_equal :left, result.blocks.first.anchor.side
      assert_equal 1, result.blocks.first.anchor.line
    end

    test "a removed file has no removed strips, since everything is removed" do
      base = Markdown::Document.parse("# Gone\n").blocks
      result = BlockMapper.call(
        head_blocks: [], base_blocks: base,
        line_sets: Diff::Patch.parse("@@ -1,1 +0,0 @@\n-# Gone\n"),
        threads: [], path: PATH, file_status: "removed"
      )

      assert_empty result.blocks.flat_map(&:removed_before)
    end

    # --- shape --------------------------------------------------------------

    test "blocks come back in document order" do
      result = map

      assert_equal result.blocks.map { |a| a.block.start_line }.sort,
                   result.blocks.map { |a| a.block.start_line }
    end

    test "all_blocks walks children depth-first" do
      result = map

      assert_operator result.all_blocks.size, :>, result.blocks.size
    end
  end
end
