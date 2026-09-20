# frozen_string_literal: true

module Webhooks
  # Splices Prism's block into, and out of, text Prism does not own.
  #
  # Pure string handling: no network, no Rails, no GitHub. Everything about
  # "never rewrite someone else's pull request description" is decided here,
  # so this is the file to read (and the test to trust) when asking whether
  # Prism can mangle a description.
  #
  # ## The guarantee
  #
  # `apply` and `remove` never change a byte outside the markers. Not
  # whitespace, not line endings, not a trailing newline. When the block is
  # already present they replace exactly the span from the first byte of the
  # begin marker to the last byte of the end marker. When it is not, they
  # append, and appending is the only way any byte outside the markers is ever
  # written.
  #
  # ## Why that still converges
  #
  # Appending needs a separator, and a naive `body + "\n\n" + block` would grow
  # the text by two newlines on every add/remove/add cycle. The separator is
  # therefore chosen from what the text already ends with:
  #
  #     ""            → ""      (nothing to separate from)
  #     "…text"       → "\n\n"  (a Markdown paragraph break)
  #     "…text\n"     → "\n"    (one newline short of a break)
  #     "…text\n\n"   → ""      (already separated)
  #
  # `remove` then deletes only the marked span, leaving the separator behind as
  # trailing whitespace. The next `apply` sees a body ending in "\n\n" and adds
  # no separator at all, so the cycle is stable from the second round on and
  # nothing accumulates. Trailing newlines render as nothing on GitHub, which
  # is why leaving them is preferable to trimming bytes we did not write.
  #
  # ## Tampering
  #
  # A body with a begin marker and no end marker (someone deleted half of it,
  # or pasted our block into a code fence) is treated as *not containing* the
  # block. We will not guess where the block ends, because guessing wrong means
  # eating the author's text.
  class MarkerBlock
    BEGIN_MARKER = "<!-- prism:begin -->"
    END_MARKER = "<!-- prism:end -->"

    class << self
      # True when `text` carries a complete, well-formed block.
      def present_in?(text)
        !span(text).nil?
      end

      # The content between the markers, or nil.
      def content_of(text)
        range = span(text)
        return nil if range.nil?

        text[range].delete_prefix(BEGIN_MARKER).delete_suffix(END_MARKER).strip
      end

      # `text` with `content` wrapped in markers, replacing an existing block in
      # place or appending one. Returns the text unchanged when the result
      # would be identical, so a caller can compare and skip the write.
      def apply(text, content)
        text = text.to_s
        block = wrap(content)
        range = span(text)

        return text.dup.tap { |result| result[range] = block } unless range.nil?

        text + separator_for(text) + block
      end

      # `text` with the block deleted and nothing else touched.
      def remove(text)
        text = text.to_s
        range = span(text)
        return text if range.nil?

        text.dup.tap { |result| result[range] = "" }
      end

      def wrap(content)
        "#{BEGIN_MARKER}\n#{content.to_s.strip}\n#{END_MARKER}"
      end

      private

      # The byte range covering the markers and everything between them, or nil
      # when there isn't exactly one well-formed block.
      #
      # `index`/`index(..., from)` rather than a regex: a regex over an
      # arbitrarily long, attacker-influenced description is a backtracking
      # risk for no benefit, and plain index calls say precisely what they do.
      def span(text)
        text = text.to_s
        opening = text.index(BEGIN_MARKER)
        return nil if opening.nil?

        closing = text.index(END_MARKER, opening + BEGIN_MARKER.length)
        return nil if closing.nil?

        opening...(closing + END_MARKER.length)
      end

      def separator_for(text)
        return "" if text.empty?
        return "" if text.end_with?("\n\n")
        return "\n" if text.end_with?("\n")

        "\n\n"
      end
    end
  end
end
