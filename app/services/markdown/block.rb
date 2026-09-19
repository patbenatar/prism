# frozen_string_literal: true

module Markdown
  # One commentable unit of a rendered Markdown file.
  #
  # Blocks form a shallow tree. Top-level blocks (paragraph, heading, list,
  # table, fenced code, blockquote, alert, html_region, front matter…) have
  # `depth == 0`. List items and table rows are their children at `depth == 1`,
  # so a reviewer can comment on a single bullet or row rather than the whole
  # list or table.
  #
  # A child's `html` is the standalone fragment for that item or row. It is
  # there for quoting and for thread context, *not* for rendering on its own —
  # a bare `<li>` outside its `<ul>` is not valid HTML. The view renders the
  # parent's `html` (which already contains its children, each carrying its own
  # `data-sourcepos`) and uses the child blocks to place gutters and threads.
  Block = Struct.new(
    :id, :type, :start_line, :end_line, :html, :plain_text,
    :depth, :parent_id, :children,
    keyword_init: true
  ) do
    def range = (start_line..end_line)

    def lines = range.to_a

    def line_count = end_line - start_line + 1

    def top_level? = depth.zero?

    def children = self[:children] ||= []

    def leaf? = children.empty?

    def covers?(line) = start_line <= line && line <= end_line

    # Self and descendants, outermost first.
    def self_and_descendants
      [ self ] + children.flat_map(&:self_and_descendants)
    end

    # The deepest block in this subtree covering `line`, or nil.
    def deepest_covering(line)
      return nil unless covers?(line)

      children.each do |child|
        found = child.deepest_covering(line)
        return found if found
      end
      self
    end
  end
end
