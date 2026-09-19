# frozen_string_literal: true

module Review
  # Where a review comment attaches on GitHub.
  #
  # Serializes to both shapes the GitHub client needs: REST
  # (`line/side/start_line/start_side/subject_type`) and GraphQL
  # (`line/side/startLine/startSide/subjectType`). Keys whose value is nil are
  # omitted — GitHub rejects an explicit null `start_line`.
  #
  # Sides are `:left` and `:right` in Ruby, "LEFT"/"RIGHT" on the wire.
  #
  # **A LEFT anchor always carries a base-side line number.** The head line that
  # now occupies a deleted line's position (`LineSets#head_line_for_base`) is a
  # display convention for placing existing threads; posting it as a LEFT anchor
  # would silently attach the comment to unrelated content.
  Anchor = Data.define(:path, :subject_type, :side, :line, :start_side, :start_line) do
    class << self
      # A single-line comment.
      def line(path:, line:, side: :right)
        new(path: path, subject_type: :line, side: side, line: line,
            start_side: nil, start_line: nil)
      end

      # A comment spanning `start_line..line`. GitHub highlights the whole range.
      def multi_line(path:, start_line:, line:, side: :right, start_side: nil)
        new(path: path, subject_type: :line, side: side, line: line,
            start_side: start_side || side, start_line: start_line)
      end

      # A comment on the file as a whole, with no line anchor. Used when no line
      # of the block is in the diff, so GitHub cannot anchor to it.
      def file(path)
        new(path: path, subject_type: :file, side: nil, line: nil,
            start_side: nil, start_line: nil)
      end
    end

    def initialize(path:, subject_type:, side:, line:, start_side:, start_line:)
      raise ArgumentError, "path is required" if path.to_s.empty?

      unless Anchor::SUBJECT_TYPES.include?(subject_type)
        raise ArgumentError, "subject_type must be one of #{Anchor::SUBJECT_TYPES.inspect}"
      end

      if subject_type == :file
        unless line.nil? && start_line.nil? && side.nil? && start_side.nil?
          raise ArgumentError, "a file anchor carries no line or side"
        end
      else
        raise ArgumentError, "line is required for a line anchor" if line.nil?
        unless Anchor::SIDES.include?(side)
          raise ArgumentError, "side must be one of #{Anchor::SIDES.inspect}"
        end

        if start_line
          unless Anchor::SIDES.include?(start_side)
            raise ArgumentError, "start_side must be one of #{Anchor::SIDES.inspect}"
          end
          # GitHub's own ordering requirement, undocumented but enforced.
          raise ArgumentError, "start_line must be before line" unless start_line < line
        elsif start_side
          raise ArgumentError, "start_side without start_line"
        end
      end

      super
    end

    def file? = subject_type == :file

    def multi_line? = !start_line.nil?

    def to_rest
      {
        path: path,
        line: line,
        side: wire_side(side),
        start_line: start_line,
        start_side: wire_side(start_side),
        subject_type: subject_type.to_s
      }.compact
    end

    # The `comments` array of POST /pulls/{n}/reviews accepts a *narrower* set of
    # keys than the standalone comment endpoint: path, body, line, side,
    # start_line, start_side and the deprecated position — and notably **not**
    # subject_type. Sending `to_rest` there is a plausible 422, so batching a
    # review's comments uses this instead.
    #
    # A file-level comment cannot be expressed in that array at all, so this
    # raises rather than quietly emitting a path with no anchor.
    def to_review_comment
      raise ArgumentError, "a file-level comment cannot go in a review's comments array" if file?

      { path: path, line: line, side: wire_side(side),
        start_line: start_line, start_side: wire_side(start_side) }.compact
    end

    def to_graphql
      {
        path: path,
        line: line,
        side: wire_side(side),
        startLine: start_line,
        startSide: wire_side(start_side),
        subjectType: subject_type.to_s.upcase
      }.compact
    end

    private

    def wire_side(value) = value&.to_s&.upcase
  end

  # Defined out here rather than inside the block: a constant assigned inside a
  # `Data.define` body lands in the enclosing module, not on the class.
  Anchor::SIDES = %i[left right].freeze
  Anchor::SUBJECT_TYPES = %i[line file].freeze
end
