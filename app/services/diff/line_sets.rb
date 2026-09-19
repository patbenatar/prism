# frozen_string_literal: true

module Diff
  # Which lines of a file GitHub will accept a review comment on, derived from
  # the unified diff in a pull request file's `patch`.
  #
  # GitHub accepts a comment only on a line that appears inside a hunk — added
  # lines, deleted lines, and the few context lines around each change. Anything
  # else is rejected with 422 "Pull request review thread line must be part of
  # the diff", from REST and GraphQL alike, even though github.com's own UI can
  # comment on expanded context.
  class LineSets
    # right: head line number => :added | :context
    # left:  base line number => :removed | :context
    attr_reader :right, :left, :right_of_left

    def initialize(right: {}, left: {}, right_of_left: {})
      @right = right.freeze
      @left = left.freeze
      @right_of_left = right_of_left.freeze
      freeze
    end

    def self.empty = new

    def empty? = right.empty? && left.empty?

    def added?(line) = right[line] == :added

    def context?(line) = right[line] == :context

    def removed?(line) = left[line] == :removed

    # The only predicate that decides whether a block can carry a line comment.
    def commentable_right?(line) = right.key?(line)

    def commentable_left?(line) = left.key?(line)

    def added_lines = right.select { |_, kind| kind == :added }.keys

    def removed_lines = left.select { |_, kind| kind == :removed }.keys

    # The head line now sitting where the given base line used to be.
    #
    # A display convention only — it places an existing LEFT-side thread next to
    # the head content that replaced it. It is NEVER a write anchor: a comment
    # on removed content is posted with side LEFT and the *base* line number.
    def head_line_for_base(base_line) = right_of_left[base_line]
  end
end
