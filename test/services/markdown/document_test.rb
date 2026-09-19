# frozen_string_literal: true

require "test_helper"

module Markdown
  class DocumentTest < ActiveSupport::TestCase
    SOURCE = <<~MD
      # Heading

      A paragraph.

      - one
      - two
        - deep

      | a | b |
      |---|---|
      | 1 | 2 |
    MD

    setup { @document = Document.parse(SOURCE) }

    test "iterates top-level blocks only" do
      assert_equal %i[heading paragraph list table], @document.map(&:type)
      assert_equal [ 0 ], @document.map(&:depth).uniq
    end

    test "all_blocks includes descendants in document order" do
      assert_equal %i[heading paragraph list item item item table table_row table_row],
                   @document.all_blocks.map(&:type)
    end

    test "block_covering returns the deepest block at a line" do
      assert_equal :heading, @document.block_covering(1).type

      item = @document.block_covering(7)
      assert_equal :item, item.type
      assert_equal 2, item.depth
      assert_equal 7..7, item.range
    end

    test "block_covering returns a table row rather than the table" do
      row = @document.block_covering(11)

      assert_equal :table_row, row.type
      assert_equal 11..11, row.range
    end

    test "top_level_covering ignores children" do
      assert_equal :list, @document.top_level_covering(7).type
    end

    test "block_covering returns nil for a line between blocks" do
      assert_nil @document.block_covering(2)
      assert_nil @document.block_covering(999)
    end

    test "find_block looks up any block by id, including children" do
      child = @document.all_blocks.find { |block| block.depth == 2 }

      assert_equal child, @document.find_block(child.id)
      assert_nil @document.find_block("nope")
    end

    test "last_line reports the end of the final block" do
      assert_equal 11, @document.last_line
    end

    test "an empty document has no blocks" do
      document = Document.parse("")

      assert_predicate document, :empty?
      assert_equal 0, document.last_line
      assert_nil document.block_covering(1)
    end
  end
end
