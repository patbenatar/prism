# frozen_string_literal: true

module Review
  # Why a block cannot carry a line-anchored comment. The UI still offers a
  # gutter affordance for these; it opens the composer in file-comment mode.
  NotCommentable = Data.define(:reason) do
    def initialize(reason:)
      unless NotCommentable::REASONS.include?(reason)
        raise ArgumentError, "unknown reason #{reason.inspect}"
      end

      super
    end

    def commentable? = false

    # Wording the composer shows above the pre-filled file comment.
    def explanation
      case reason
      when :outside_diff
        "This block isn't part of the PR diff, so GitHub can't anchor a comment to it."
      when :no_patch
        "GitHub didn't provide a diff for this file, so there are no lines to anchor to."
      when :file_removed
        "This file was removed in this pull request."
      end
    end
  end

  # Defined out here rather than inside the block: a constant assigned inside a
  # `Data.define` body lands in the enclosing module, not on the class.
  NotCommentable::REASONS = %i[outside_diff no_patch file_removed].freeze
end
