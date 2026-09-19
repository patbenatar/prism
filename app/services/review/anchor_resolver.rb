# frozen_string_literal: true

module Review
  # Decides which source line (or range) a comment on a rendered block posts to.
  #
  # Rule, in order:
  #   1. Take the block's lines that are in the diff on the requested side.
  #   2. Empty  -> not line-commentable; the UI offers a file comment instead.
  #   3. A contiguous run of 2 or more -> a multi-line anchor covering the run.
  #      Both endpoints come from the in-diff set, so GitHub's "both ends must be
  #      in the diff" rule holds by construction.
  #   4. Otherwise a single line: the first *added* line in the block, else the
  #      first in-diff line. GitHub cannot express a gapped range, and a spanning
  #      anchor would claim lines that are not in the diff.
  module AnchorResolver
    class << self
      # @return [Review::Anchor, Review::NotCommentable]
      def call(block, line_sets, path:, side: :right)
        return NotCommentable.new(reason: :no_patch) if line_sets.empty?

        in_diff = in_diff_lines(block, line_sets, side)
        return NotCommentable.new(reason: :outside_diff) if in_diff.empty?

        if in_diff.size > 1 && contiguous?(in_diff)
          Anchor.multi_line(path: path, start_line: in_diff.first,
                            line: in_diff.last, side: side)
        else
          Anchor.line(path: path, line: single_line(block, line_sets, in_diff, side),
                      side: side)
        end
      end

      private

      def in_diff_lines(block, line_sets, side)
        block.lines.select do |line|
          side == :left ? line_sets.commentable_left?(line) : line_sets.commentable_right?(line)
        end
      end

      def contiguous?(lines)
        lines.each_cons(2).all? { |a, b| b == a + 1 }
      end

      # Prefer a line the PR actually changed, so the comment lands on the edit
      # rather than on surrounding context.
      def single_line(block, line_sets, in_diff, side)
        changed = block.lines.find do |line|
          side == :left ? line_sets.removed?(line) : line_sets.added?(line)
        end
        changed || in_diff.first
      end
    end
  end
end
