# frozen_string_literal: true

module Markdown
  # A parsed Markdown file: its top-level blocks, plus lookups the view and the
  # review mapper need.
  #
  # `blocks` are the top-level (depth 0) blocks in document order. Each may have
  # children (list items, table rows) reachable through `Block#children`.
  class Document
    include Enumerable

    attr_reader :blocks

    def self.parse(text, renderer: Renderer.new)
      new(renderer.call(text))
    end

    def initialize(blocks)
      @blocks = blocks.freeze
    end

    # Top-level blocks, in document order.
    def each(&) = blocks.each(&)

    def empty? = blocks.empty?

    # Every block at every depth, outermost first, in document order.
    def all_blocks
      @all_blocks ||= blocks.flat_map(&:self_and_descendants).freeze
    end

    def find_block(id) = index[id]

    # The most specific block containing `line` — a list item rather than the
    # list, a table row rather than the table — or nil if no block covers it
    # (blank lines between blocks belong to nothing).
    def block_covering(line)
      blocks.each do |block|
        found = block.deepest_covering(line)
        return found if found
      end
      nil
    end

    # The top-level block containing `line`, ignoring children.
    def top_level_covering(line)
      blocks.find { |block| block.covers?(line) }
    end

    def last_line = blocks.map(&:end_line).max || 0

    private

    def index
      @index ||= all_blocks.index_by(&:id)
    end
  end
end
