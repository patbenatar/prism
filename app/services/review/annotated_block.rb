# frozen_string_literal: true

module Review
  # A rendered block with everything the file view needs to draw it: how it
  # changed, whether it can take a line comment, where such a comment would go,
  # the threads already on it, and any content deleted just before it.
  AnnotatedBlock = Data.define(
    :block, :change, :commentable, :uncommentable_reason, :anchor,
    :threads, :removed_before, :children
  ) do
    def added? = change == :added

    def modified? = change == :modified

    def changed? = change != :unchanged

    def commentable? = commentable

    def threads? = threads.any?

    def removed_before? = removed_before.any?

    # Depth-first, matching the order the view renders them.
    def self_and_descendants
      [ self ] + children.flat_map(&:self_and_descendants)
    end
  end

  # Defined out here rather than inside the block: a constant assigned inside a
  # `Data.define` body lands in the enclosing module, not on the class.
  AnnotatedBlock::CHANGES = %i[added modified unchanged].freeze
end
