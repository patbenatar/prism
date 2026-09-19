# frozen_string_literal: true

module Diff
  # Parses the unified diff GitHub returns in a pull request file's `patch`
  # into a {Diff::LineSets}.
  #
  # The patch has its file headers stripped, starts at the first `@@`, and has
  # no trailing newline. Three details bite in practice and are covered by tests:
  #
  #   * hunk counts are optional — `@@ -3 +3 @@` is as valid as `@@ -3,4 +3,5 @@`
  #   * `\ No newline at end of file` consumes no line on either side
  #   * a context line that is blank in the file arrives as a single space, and
  #     some producers strip that trailing whitespace, leaving an empty string.
  #     It must still count as context, or every later line in the hunk is off
  #     by one.
  module Patch
    HUNK = /\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/

    class << self
      # @param patch [String, nil] nil for binary files, pure renames, and diffs
      #   GitHub declines to send
      # @return [Diff::LineSets]
      def parse(patch)
        return LineSets.empty if patch.blank?

        right = {}
        left = {}
        right_of_left = {}
        base = nil
        head = nil

        patch.each_line do |raw|
          line = raw.chomp

          if (match = HUNK.match(line))
            base = match[1].to_i
            head = match[3].to_i
            next
          end

          next if base.nil?  # preamble before the first hunk header

          case line[0]
          when "+"
            right[head] = :added
            head += 1
          when "-"
            left[base] = :removed
            right_of_left[base] = head
            base += 1
          when "\\"
            next             # "\ No newline at end of file"
          else               # " " context, and the empty-string case
            right[head] = :context
            left[base] = :context
            right_of_left[base] = head
            base += 1
            head += 1
          end
        end

        LineSets.new(right: right, left: left, right_of_left: right_of_left)
      end
    end
  end
end
