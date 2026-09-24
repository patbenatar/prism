# frozen_string_literal: true

module Review
  # Which stretches of a modified file are worth hiding, so a two-line edit in
  # a long document is not buried in the document.
  #
  # Splits a file's annotated blocks into segments the view renders either
  # openly or behind an expander. The unit is a **block**, not a line, because
  # a block is what Prism renders and what a reviewer comments on — a
  # paragraph, a heading, a list, a table.
  #
  # Four rules, in the order they matter:
  #
  # 1. **A block that carries a comment is never hidden.** Not the block's own
  #    threads and not a list item's or a table row's, and not a block with
  #    content deleted just before it — that strip is the only place those
  #    deleted lines appear on the page. A hidden comment is a lost comment,
  #    and this rule has no exceptions.
  # 2. **Changed blocks show, with CONTEXT blocks either side.**
  # 3. **A gap shorter than MINIMUM is not worth an expander** and stays open.
  # 4. **A file with nothing changed collapses nothing.** A pure rename, a
  #    diff GitHub withheld, a file whose changes all fall outside the side we
  #    render: the reviewer opened it to read it, and "hide everything
  #    unchanged" would hide the whole document. Same for a file the pull
  #    request deletes, where every block is the thing being deleted.
  class CollapsedRuns
    # Blocks of context either side of a change.
    #
    # Two, not three and not one. A Markdown block is a whole paragraph,
    # heading, list or table, so a single block of context is already several
    # lines — far more than the three lines GitHub shows around a diff hunk.
    # Two reaches reliably past the paragraph immediately above a change to
    # the heading that names the section, which is the context that says what
    # the change is *about*. Three leaves only token runs collapsed in a
    # typical documentation file, which is furniture for no gain.
    CONTEXT = 2

    # Below this, showing the blocks costs less than the control that hides
    # them: an expander is itself a line of page furniture, so collapsing two
    # paragraphs trades two paragraphs for one control and a click.
    MINIMUM = 3

    Segment = Data.define(:collapsed, :blocks) do
      def collapsed? = collapsed

      def size = blocks.size
    end

    def self.call(blocks, removed_file: false)
      new(blocks, removed_file: removed_file).segments
    end

    def initialize(blocks, removed_file: false)
      @blocks = Array(blocks)
      @removed_file = removed_file
    end

    # Indexes throughout, never the blocks themselves: an AnnotatedBlock is a
    # value object, so two blocks holding the same paragraph are `==` and
    # anything that looked a block up by identity would find the wrong one.
    def segments
      return [] if blocks.empty?
      return [ shown(blocks) ] if nothing_to_hide?

      (0...blocks.size).chunk { |index| hidden_indexes.include?(index) }
                       .map { |hidden, run| Segment.new(collapsed: hidden, blocks: blocks.values_at(*run)) }
    end

    private

    attr_reader :blocks

    # Rule 4. `removed_file` is the view's own notion — every block of a
    # deleted file reads as removed whatever the mapper called it — so it is
    # asked about separately rather than inferred.
    def nothing_to_hide?
      @removed_file || blocks.none?(&:changed?)
    end

    def shown(run) = Segment.new(collapsed: false, blocks: run)

    # Everything that stays open, worked out once: the changed blocks, their
    # context, and every block that must never be hidden. What is left over in
    # runs of at least MINIMUM is what collapses.
    def hidden_indexes
      @hidden_indexes ||= begin
        open = Set.new

        blocks.each_with_index do |block, index|
          # Both, never one or the other. A block that replaces a line is
          # *changed* and also carries the removed strip for the line it
          # replaced, so it is pinned too — and an early `next` here would
          # have held it open while silently folding away the context either
          # side of it, which is the context a reviewer needs most.
          open << index if pinned?(block)
          next unless block.changed?

          ((index - CONTEXT)..(index + CONTEXT)).each { |i| open << i if i.between?(0, blocks.size - 1) }
        end

        hidden = (0...blocks.size).to_a - open.to_a
        hidden.chunk_while { |a, b| b == a + 1 }.select { |run| run.size >= MINIMUM }.flatten.to_set
      end
    end

    # Rule 1. `self_and_descendants` because a thread can sit on one list item
    # or one table row rather than on the block that contains it.
    def pinned?(block)
      block.removed_before? || block.self_and_descendants.any?(&:threads?)
    end
  end
end
