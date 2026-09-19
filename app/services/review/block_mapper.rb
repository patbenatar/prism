# frozen_string_literal: true

module Review
  # Joins the three inputs the rendered file view needs — the rendered blocks,
  # the diff, and the threads already on GitHub — into one ordered structure.
  #
  # v1 renders the HEAD side of the file plus collapsed strips of deleted
  # content. A file whose status is "removed" has no head side at all, so it
  # renders from the BASE blocks with LEFT anchors instead.
  module BlockMapper
    Result = Data.define(:blocks, :file_threads, :outdated_threads, :unplaced_threads,
                         :trailing_removed, :removed_strip_threads, :side) do
      def removed_file? = side == :left

      def all_blocks = blocks.flat_map(&:self_and_descendants)

      # Every strip rendered on the page: the ones sitting before a head block
      # and the ones that ran off the end.
      def removed_strips = blocks.flat_map(&:removed_before) + trailing_removed

      # Threads on a deleted block, keyed by that block's id.
      def threads_for_strip(block) = removed_strip_threads.fetch(block.id, [])
    end

    # GraphQL DiffSide / subject type values, normalized.
    RIGHT = "RIGHT"
    LEFT = "LEFT"
    FILE = "FILE"

    class << self
      def call(head_blocks:, base_blocks:, line_sets:, threads:, path:, file_status: "modified")
        removed_file = file_status.to_s == "removed"
        side = removed_file ? :left : :right
        blocks = removed_file ? base_blocks : head_blocks

        strips, trailing =
          removed_file ? [ {}, [] ] : removed_strips(base_blocks, blocks, line_sets)
        strip_blocks = strips.values.flatten + trailing
        buckets = bucket_threads(threads, blocks, line_sets, side, strip_blocks)

        annotated = blocks.map do |block|
          annotate(block, line_sets: line_sets, path: path, side: side,
                          threads_by_block: buckets.by_block,
                          removed_before: strips.fetch(block.id, []),
                          file_status: file_status)
        end

        Result.new(blocks: annotated, file_threads: buckets.file,
                   outdated_threads: buckets.outdated, unplaced_threads: buckets.unplaced,
                   trailing_removed: trailing, removed_strip_threads: buckets.by_strip,
                   side: side)
      end

      private

      # --- annotation -------------------------------------------------------

      def annotate(block, line_sets:, path:, side:, threads_by_block:, removed_before:, file_status:)
        anchor = AnchorResolver.call(block, line_sets, path: path, side: side)
        commentable = anchor.is_a?(Anchor)

        AnnotatedBlock.new(
          block: block,
          change: change_for(block, line_sets, side, file_status),
          commentable: commentable,
          uncommentable_reason: commentable ? nil : reason_for(anchor, file_status),
          anchor: commentable ? anchor : nil,
          threads: threads_by_block.fetch(block.id, []),
          removed_before: removed_before,
          children: block.children.map do |child|
            annotate(child, line_sets: line_sets, path: path, side: side,
                            threads_by_block: threads_by_block,
                            removed_before: [], file_status: file_status)
          end
        )
      end

      def reason_for(result, file_status)
        return :file_removed if file_status.to_s == "removed" && result.reason == :outside_diff

        result.reason
      end

      # Added wins over modified: a block containing new lines reads as new.
      # A block spanning two hunks is highlighted whole rather than in pieces,
      # because the rendered view has no line granularity.
      def change_for(block, line_sets, side, file_status)
        return :added if file_status.to_s == "added" && line_sets.empty?

        if side == :left
          return :modified if block.lines.any? { |line| line_sets.removed?(line) }

          return :unchanged
        end

        return :added if block.lines.any? { |line| line_sets.added?(line) }
        return :modified if deletions_inside?(block, line_sets)

        :unchanged
      end

      # A deletion has no head line of its own; it sits in front of one. If that
      # head line falls inside the block, the block lost content.
      def deletions_inside?(block, line_sets)
        line_sets.removed_lines.any? do |base_line|
          head = line_sets.head_line_for_base(base_line)
          head && block.covers?(head)
        end
      end

      # --- thread placement -------------------------------------------------

      Buckets = Struct.new(:by_block, :by_strip, :file, :outdated, :unplaced)

      def bucket_threads(threads, blocks, line_sets, side, strip_blocks)
        buckets = Buckets.new(Hash.new { |hash, key| hash[key] = [] },
                              Hash.new { |hash, key| hash[key] = [] }, [], [], [])

        Array(threads).each do |thread|
          if subject_type(thread) == FILE
            buckets.file << thread
          elsif outdated?(thread)
            buckets.outdated << thread
          else
            place_line_thread(thread, blocks, line_sets, side, strip_blocks, buckets)
          end
        end

        buckets
      end

      def place_line_thread(thread, blocks, line_sets, side, strip_blocks, buckets)
        line = thread_line(thread)
        return buckets.outdated << thread if line.nil?

        unless diff_side(thread) == LEFT && side == :right
          target = deepest_covering(blocks, line)
          return target ? buckets.by_block[target.id] << thread : buckets.unplaced << thread
        end

        # A comment on a deleted line. If that line belongs to a block we render
        # as a removed strip, it goes on the strip, which still shows the text
        # the comment is about. Otherwise show it beside whatever now occupies
        # that spot — display only, never used to post.
        strip = strip_blocks.find { |block| block.covers?(line) }
        return buckets.by_strip[strip.id] << thread if strip

        head = line_sets.head_line_for_base(line)
        target = head && deepest_covering(blocks, head)
        target ? buckets.by_block[target.id] << thread : buckets.unplaced << thread
      end

      def deepest_covering(blocks, line)
        blocks.each do |block|
          found = block.deepest_covering(line)
          return found if found
        end
        nil
      end

      # --- removed strips ---------------------------------------------------

      # Base blocks whose lines are *all* deletions no longer exist on the head
      # side. Each is shown as a collapsed strip immediately before the head
      # block that now occupies its position. A block with a mix of deleted and
      # context lines still exists in modified form, and its head counterpart is
      # already marked :modified.
      # Returns [strips_by_head_block_id, trailing].
      #
      # Content deleted from the *end* of a file maps to a head line past every
      # head block, so it has nothing to sit before. Those blocks go to
      # `trailing_removed` rather than being dropped — silently losing a
      # deletion would tell the reviewer the content is still there.
      def removed_strips(base_blocks, head_blocks, line_sets)
        return [ {}, [] ] if base_blocks.blank? || line_sets.empty?

        strips = {}
        trailing = []

        base_blocks.each do |block|
          next unless block.lines.all? { |line| line_sets.removed?(line) }

          head = line_sets.head_line_for_base(block.start_line)
          # Prefer the block that now covers that spot; if the head line is
          # blank (between blocks), fall back to the next block after it.
          anchor_block = head && (head_blocks.find { |candidate| candidate.covers?(head) } ||
                                  head_blocks.find { |candidate| candidate.start_line >= head })

          if anchor_block
            (strips[anchor_block.id] ||= []) << block
          else
            trailing << block
          end
        end

        [ strips, trailing ]
      end

      # --- thread attribute access -----------------------------------------
      # Written against the PLAN's Github::Types::ReviewThread shape, tolerating
      # both string and symbol enum values.

      def subject_type(thread) = normalize(value(thread, :subject_type))

      def diff_side(thread) = normalize(value(thread, :diff_side)) || RIGHT

      def thread_line(thread) = value(thread, :line)

      def outdated?(thread)
        return true if value(thread, :is_outdated)

        thread_line(thread).nil?
      end

      def value(thread, name)
        thread.respond_to?(name) ? thread.public_send(name) : nil
      end

      def normalize(enum) = enum&.to_s&.upcase
    end
  end
end
