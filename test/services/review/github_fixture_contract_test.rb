# frozen_string_literal: true

require "test_helper"

module Review
  # A contract test across workstreams: the GitHub fixtures are built by the
  # client's author from real API shapes, and this asserts the Markdown/diff
  # engine reads them correctly.
  #
  # The assertions are *derived* from each fixture rather than hard-coded, so
  # editing a fixture's content does not break them. What they pin is the
  # relationship between a patch and the line sets it must produce, which is
  # exactly what the fixture's traps are designed to break.
  class GithubFixtureContractTest < ActiveSupport::TestCase
    FIXTURES = Rails.root.join("test/fixtures/github")
    HUNK = /\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/

    def files
      data = JSON.parse(File.read(FIXTURES.join("pull_files.json")))
      data = data["files"] || data.values.first if data.is_a?(Hash)
      data
    end

    def file(path) = files.find { |entry| (entry["filename"] || entry["path"]) == path }

    def sets_for(path) = Diff::Patch.parse(file(path)["patch"])

    # --- the invariant the fixture's traps attack ---------------------------

    test "every hunk yields exactly the line count its header declares" do
      # A hunk header `@@ -a,b +c,d @@` promises b lines on the base side and d
      # on the head side. The fixture deliberately contains a bare empty-string
      # context line and a bare "+", either of which desynchronises the count if
      # mishandled — so this catches the trap without naming a line number.
      files.each do |entry|
        patch = entry["patch"]
        next if patch.nil?

        path = entry["filename"] || entry["path"]
        sets = Diff::Patch.parse(patch)

        each_hunk(patch) do |base_start, base_len, head_start, head_len|
          right = sets.right.keys.select { |line| line.between?(head_start, head_start + head_len - 1) }
          left = sets.left.keys.select { |line| line.between?(base_start, base_start + base_len - 1) }

          assert_equal head_len, right.size, "#{path}: head side of hunk at #{head_start}"
          assert_equal base_len, left.size, "#{path}: base side of hunk at #{base_start}"
        end
      end
    end

    test "hunk lines are contiguous, so nothing was skipped mid-hunk" do
      files.each do |entry|
        next if entry["patch"].nil?

        sets = Diff::Patch.parse(entry["patch"])

        each_hunk(entry["patch"]) do |_base_start, _base_len, head_start, head_len|
          expected = (head_start...(head_start + head_len)).to_a
          actual = sets.right.keys.select { |line| expected.include?(line) }.sort

          assert_equal expected, actual, entry["filename"] || entry["path"]
        end
      end
    end

    test "a line outside every hunk is never commentable" do
      sets = sets_for("docs/guide.md")
      covered = hunk_ranges(file("docs/guide.md")["patch"]).flat_map(&:to_a)
      outside = ((1..(covered.max + 20)).to_a - covered).first(5)

      assert_not_empty outside, "the fixture needs a gap between hunks to be useful"
      outside.each { |line| assert_not sets.commentable_right?(line), "line #{line}" }
    end

    # --- file statuses ------------------------------------------------------

    test "each file status parses to the side it should occupy" do
      files.each do |entry|
        path = entry["filename"] || entry["path"]
        sets = Diff::Patch.parse(entry["patch"])

        case entry["status"]
        when "added"
          assert_equal sets.right.keys.sort, sets.added_lines.sort, "#{path} is all additions"
          assert_empty sets.left, "#{path} has no base side"
        when "removed"
          assert_equal sets.left.keys.sort, sets.removed_lines.sort, "#{path} is all deletions"
          assert_empty sets.right, "#{path} has no head side"
        end
      end
    end

    test "a file with no patch yields empty sets rather than raising" do
      without = files.reject { |entry| entry["patch"] }

      assert_not_empty without, "the fixture needs a rename or binary to be useful"
      without.each do |entry|
        assert_predicate Diff::Patch.parse(entry["patch"]), :empty?,
                         entry["filename"] || entry["path"]
      end
    end

    # --- the mapper against the parser --------------------------------------

    test "commentability agrees with the line sets, block by block" do
      sets = sets_for("docs/guide.md")

      map_guide.all_blocks.each do |annotated|
        in_diff = annotated.block.lines.any? { |line| sets.commentable_right?(line) }

        assert_equal in_diff, annotated.commentable?,
          "#{annotated.block.type} #{annotated.block.range} disagrees with the diff"
      end
    end

    test "every anchor points at a line the diff actually contains" do
      sets = sets_for("docs/guide.md")

      map_guide.all_blocks.filter_map(&:anchor).each do |anchor|
        assert sets.commentable_right?(anchor.line), "anchor line #{anchor.line} is outside the diff"
        next if anchor.start_line.nil?

        assert sets.commentable_right?(anchor.start_line), "start_line #{anchor.start_line} is outside"
        assert_operator anchor.start_line, :<, anchor.line
      end
    end

    test "the fixture exercises the multi-line anchor path end to end" do
      # Until the guide.md patch was corrected, no block's in-diff lines formed a
      # contiguous run of two or more, so the multi-line branch never ran against
      # real data. Assert it does, rather than trusting it stays that way.
      anchors = map_guide.all_blocks.filter_map(&:anchor)
      multi = anchors.select(&:multi_line?)

      assert_not_empty multi, "no multi-line anchor: the fixture no longer covers the range path"
      multi.each do |anchor|
        assert_operator anchor.start_line, :<, anchor.line
        assert_equal anchor.side, anchor.start_side
        assert_equal "RIGHT", anchor.to_graphql[:startSide]
      end
    end

    test "a block is marked added exactly when it contains an added line" do
      sets = sets_for("docs/guide.md")

      map_guide.blocks.each do |annotated|
        contains_added = annotated.block.lines.any? { |line| sets.added?(line) }

        assert_equal contains_added, annotated.added?, "#{annotated.block.range}"
      end
    end

    test "blocks between the hunks report outside_diff, not a missing patch" do
      outside = map_guide.blocks.reject(&:commentable?)

      assert_not_empty outside, "the fixture needs an uncommentable block to be useful"
      assert_equal [ :outside_diff ], outside.map(&:uncommentable_reason).uniq
    end

    test "a fully deleted base block surfaces rather than disappearing" do
      # Every base block whose lines are all deletions must appear somewhere:
      # before the head block that replaced it, or after the last one when it
      # was deleted from the end of the file.
      sets = sets_for("docs/guide.md")
      base = Markdown::Document.parse(File.read(FIXTURES.join("guide_base.md"))).blocks
      fully_removed = base.select { |block| block.lines.all? { |line| sets.removed?(line) } }

      assert_not_empty fully_removed, "the fixture needs a fully deleted base block"

      result = map_guide(base_blocks: base)
      surfaced = result.blocks.flat_map(&:removed_before) + result.trailing_removed

      assert_equal fully_removed.map(&:plain_text).sort, surfaced.map(&:plain_text).sort
    end

    test "a base block that kept any line is a modification, not a removal" do
      sets = sets_for("docs/guide.md")
      base = Markdown::Document.parse(File.read(FIXTURES.join("guide_base.md"))).blocks
      partial = base.select do |block|
        block.lines.any? { |line| sets.removed?(line) } &&
          !block.lines.all? { |line| sets.removed?(line) }
      end

      assert_not_empty partial, "the fixture needs a partly deleted base block"

      result = map_guide(base_blocks: base)
      surfaced = (result.blocks.flat_map(&:removed_before) + result.trailing_removed).map(&:plain_text)

      partial.each { |block| assert_not_includes surfaced, block.plain_text }
    end

    # --- thread bucketing ---------------------------------------------------

    test "threads land in the buckets their own fields call for" do
      threads = fixture_threads
      result = map_guide(threads: threads)

      expected_file = threads.count { |thread| thread.subject_type == "FILE" }
      expected_outdated = threads.count do |thread|
        thread.subject_type != "FILE" && (thread.is_outdated || thread.line.nil?)
      end

      assert_operator expected_file, :>, 0, "the fixture needs a file-level thread"
      assert_operator expected_outdated, :>, 0, "the fixture needs an outdated thread"
      assert_equal expected_file, result.file_threads.size
      assert_equal expected_outdated, result.outdated_threads.size
      assert_empty result.unplaced_threads
    end

    test "every placed thread sits on a block whose range covers its line" do
      sets = sets_for("docs/guide.md")
      result = map_guide(threads: fixture_threads)
      placed = result.all_blocks.select { |annotated| annotated.threads.any? }

      assert_not_empty placed
      placed.each do |annotated|
        annotated.threads.each do |thread|
          line = thread.diff_side == "LEFT" ? sets.head_line_for_base(thread.line) : thread.line

          assert annotated.block.covers?(line),
            "thread on #{thread.diff_side} line #{thread.line} sits on #{annotated.block.range}"
        end
      end
    end

    test "a LEFT thread is placed through the base-to-head mapping" do
      sets = sets_for("docs/guide.md")
      left = fixture_threads.select { |thread| thread.diff_side == "LEFT" && thread.line }

      assert_not_empty left, "the fixture needs a left-side thread"
      result = map_guide(threads: left)

      assert_empty result.unplaced_threads
      placed = result.all_blocks.find { |annotated| annotated.threads.any? }

      assert placed
      # The deleted base line maps to a head line, and the thread hangs on
      # whichever block now covers it — which may start earlier than that line.
      assert placed.block.covers?(sets.head_line_for_base(left.first.line)),
        "mapped head line is outside the block the thread landed on"
    end

    private

    def each_hunk(patch)
      patch.each_line do |line|
        next unless (match = HUNK.match(line.chomp))

        yield match[1].to_i, (match[2] || 1).to_i, match[3].to_i, (match[4] || 1).to_i
      end
    end

    def hunk_ranges(patch)
      ranges = []
      each_hunk(patch) { |_bs, _bl, head_start, head_len| ranges << (head_start...(head_start + head_len)) }
      ranges
    end

    def map_guide(threads: [], base_blocks: [])
      source = File.read(FIXTURES.join("guide.md"))

      BlockMapper.call(
        head_blocks: Markdown::Document.parse(source).blocks, base_blocks: base_blocks,
        line_sets: sets_for("docs/guide.md"), threads: threads,
        path: "docs/guide.md", file_status: "modified"
      )
    end

    def fixture_threads
      raw = JSON.parse(File.read(FIXTURES.join("review_threads.json")), symbolize_names: true)
      nodes = raw.dig(:data, :repository, :pullRequest, :reviewThreads, :nodes) || []
      client = Github::Client.allocate

      nodes.map { |node| client.send(:build_thread, node) }
    end
  end
end
