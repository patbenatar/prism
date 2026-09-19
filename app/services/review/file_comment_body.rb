# frozen_string_literal: true

module Review
  # Builds the body for a file-level comment standing in for a block comment.
  #
  # When no line of a block is in the diff, GitHub cannot anchor a comment to
  # it. Rather than dropping the affordance, Prism posts a file-level comment
  # that quotes the block and links to it, so the thread still says what it is
  # about.
  module FileCommentBody
    MAX_QUOTE = 300

    class << self
      def call(block:, owner:, repo:, head_sha:, path:, body:)
        [ quote(block), permalink(owner:, repo:, head_sha:, path:, block:), "", body.to_s.strip ]
          .join("\n")
      end

      def permalink(owner:, repo:, head_sha:, path:, block:)
        anchor =
          if block.start_line == block.end_line
            "L#{block.start_line}"
          else
            "L#{block.start_line}-L#{block.end_line}"
          end

        "https://github.com/#{owner}/#{repo}/blob/#{head_sha}/#{path}##{anchor}"
      end

      private

      # A Markdown blockquote of the block's text. Every line is prefixed, so a
      # multi-line quote stays inside the quote rather than breaking out of it.
      def quote(block)
        text = truncate(block.plain_text.to_s)
        return "> _(empty block)_" if text.empty?

        text.split("\n").map { |line| "> #{line}" }.join("\n")
      end

      def truncate(text)
        return text if text.length <= MAX_QUOTE

        "#{text[0, MAX_QUOTE].rstrip}…"
      end
    end
  end
end
