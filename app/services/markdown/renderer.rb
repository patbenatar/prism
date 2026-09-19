# frozen_string_literal: true

require "digest"

module Markdown
  # Turns Markdown source into an ordered tree of {Markdown::Block}s, each
  # carrying the source line range it came from.
  #
  # We walk the commonmarker AST rather than parsing the HTML renderer's output,
  # because raw HTML blocks get no `data-sourcepos` in the HTML output but do
  # carry a source position in the AST. Walking the tree also gives us a stable
  # block identity and a clean seam for the view's comment gutter.
  #
  # Verified comrak behaviour this class relies on (see
  # docs/research/markdown-mapping.md): per-node `to_html` re-emits *absolute*
  # sourcepos values, so an extracted node stays self-describing.
  class Renderer
    EXTENSION = {
      table: true,
      tasklist: true,
      strikethrough: true,
      autolink: true,
      tagfilter: true,
      footnotes: true,
      header_ids: "user-content-",
      front_matter_delimiter: "---",
      alerts: true,
      math_dollars: true,
      math_code: true
    }.freeze

    RENDER = {
      sourcepos: true,
      unsafe: true,          # raw HTML is emitted, then sanitized by us
      hardbreaks: false,     # .md files use soft breaks; comments do not
      github_pre_lang: true,
      escaped_char_spans: false,
      tasklist_classes: true
    }.freeze

    PARSE_OPTIONS = { extension: EXTENSION }.freeze
    RENDER_OPTIONS = { extension: EXTENSION, render: RENDER }.freeze
    PLUGINS = { syntax_highlighter: nil }.freeze

    # An unclosed raw-HTML block absorbs following nodes until it balances (a
    # `<details>` wrapping Markdown parses as two separate html_block nodes).
    # These caps stop a pathological file — a stray `<div>` near the top — from
    # swallowing the rest of the document into one uncommentable region.
    MAX_HTML_REGION_NODES = 20
    MAX_HTML_REGION_LINES = 200

    # Which descendants of a rendered block become child blocks. We read these
    # back out of the parent's own HTML rather than rendering the AST nodes:
    # `to_html` on a table_row node *panics the Rust extension* ("rendered a
    # table cell without a containing table"), which aborts the process instead
    # of raising, and `to_html` on a list item renders it loose even when the
    # parent list is tight. Extracting from the parent's HTML avoids both and
    # guarantees the child markup is exactly what the page shows.
    CHILD_TAGS = { list: %w[li], table: %w[tr] }.freeze
    CHILD_TYPES = { "li" => :item, "tr" => :table_row }.freeze
    SOURCEPOS = /\A(\d+):(\d+)-(\d+):(\d+)\z/

    # Tag scanning for the html_region balance check.
    TAG = /<(\/?)([a-zA-Z][a-zA-Z0-9-]*)(?:\s[^>]*?)?(\/?)>/
    COMMENT_OR_DECLARATION = /<!--.*?-->|<![^>]*>|<\?.*?\?>/m
    VOID_ELEMENTS = %w[
      area base br col embed hr img input link meta param source track wbr
    ].freeze

    def call(markdown)
      source = normalize(markdown)
      return [] if source.empty?

      document = Commonmarker.parse(source, options: PARSE_OPTIONS)
      counter = Counter.new

      regions(document, source).map do |region|
        build_block(region, source: source, counter: counter, depth: 0, parent_id: nil)
      end
    end

    private

    # BOM and CRLF do not shift comrak's line numbers, but normalizing keeps our
    # own line slicing of the source consistent with them, and keeps columns
    # honest for anything that later wants them.
    def normalize(markdown)
      markdown.to_s.delete_prefix("\uFEFF").gsub("\r\n", "\n")
    end

    # --- source positions ---------------------------------------------------

    # comrak reports the last <li> of some lists as ending on the *following*
    # line with `end_column == 0`. The zero column makes it unambiguous.
    def clamp(node)
      position = node.source_position
      first = position[:start_line]
      last = position[:end_line]
      last -= 1 if position[:end_column].to_i.zero? && last > first
      [ first, [ last, first ].max ]
    end

    # --- html region coalescing ---------------------------------------------

    Region = Struct.new(:type, :start_line, :end_line, :html, keyword_init: true)

    def regions(document, source)
      out = []
      pending = nil

      document.each do |node|
        first, last = clamp(node)
        html = render_node(node, source: source, first: first, last: last)

        if pending
          pending.absorb(last, html)
          if flush_pending?(pending)
            out << pending.to_region
            pending = nil
          end
        elsif node.type == :html_block && unbalanced?(html)
          pending = PendingRegion.new(first, last, html.dup)
        else
          out << Region.new(type: node.type, start_line: first, end_line: last,
                            html: html)
        end
      end

      out << pending.to_region if pending
      out
    end

    # Flush as soon as the region balances, or when it hits a cap — an unclosed
    # tag must not be able to swallow the rest of the file.
    def flush_pending?(pending)
      !unbalanced?(pending.html) ||
        pending.node_count >= MAX_HTML_REGION_NODES ||
        pending.line_count >= MAX_HTML_REGION_LINES
    end

    # Net tag depth of a raw HTML fragment: positive means it leaves elements
    # open, zero means it is self-contained.
    #
    # Counting tags rather than comparing a parser round-trip matters. A
    # round-trip also "changes" perfectly balanced markup that merely gets
    # normalized — unquoted attributes, uppercase tags, a self-closing `<img />`,
    # a boolean `checked` — and READMEs are full of exactly that. Treating those
    # as unclosed made them swallow the following blocks into one uncommentable
    # region.
    def unbalanced?(html)
      depth(html).positive?
    end

    def depth(html)
      scanned = html.gsub(COMMENT_OR_DECLARATION, "")
      level = 0

      scanned.scan(TAG) do |closing, name, self_closing|
        next if VOID_ELEMENTS.include?(name.downcase)
        next if self_closing == "/"

        level += closing == "/" ? -1 : 1
      end
      level
    end

    class PendingRegion
      attr_reader :start_line, :end_line, :html, :node_count

      def initialize(start_line, end_line, html)
        @start_line = start_line
        @end_line = end_line
        @html = html
        @node_count = 1
      end

      def absorb(end_line, html)
        @end_line = end_line
        @html << html
        @node_count += 1
      end

      def line_count = end_line - start_line + 1

      def to_region
        Renderer::Region.new(type: :html_region, start_line: start_line,
                             end_line: end_line, html: html)
      end
    end

    # --- rendering ----------------------------------------------------------

    def render_node(node, source:, first:, last:)
      return front_matter_html(source, first, last) if node.type == :frontmatter

      node.to_html(options: RENDER_OPTIONS, plugins: PLUGINS)
    end

    # Front matter is frequently the thing a docs PR changes, so we keep it as a
    # block rather than dropping it, rendered as a collapsed metadata table.
    def front_matter_html(source, first, last)
      lines = source.lines[(first - 1)...last].to_a.map(&:chomp)
      body = lines.reject { |line| line.strip == "---" || line.strip.empty? }
      rows = body.filter_map { |line| line.match(/\A([\w.\-]+):[ \t]*(.*)\z/)&.captures }

      inner =
        if rows.size == body.size && rows.any?
          cells = rows.map do |key, value|
            "<tr><th scope=\"row\">#{ERB::Util.html_escape(key)}</th>" \
              "<td>#{ERB::Util.html_escape(value)}</td></tr>"
          end
          "<table><tbody>#{cells.join}</tbody></table>"
        else
          "<pre><code>#{ERB::Util.html_escape(body.join("\n"))}</code></pre>"
        end

      "<details class=\"md-front-matter\"><summary>Front matter</summary>#{inner}</details>"
    end

    # --- block building -----------------------------------------------------

    def build_block(region, source:, counter:, depth:, parent_id:)
      html = Sanitizer.call(Highlighter.call(region.html))
      id = block_id(counter.next, region.start_line, region.end_line, html)

      block = Block.new(
        id: id,
        type: region.type,
        start_line: region.start_line,
        end_line: region.end_line,
        html: html,
        plain_text: plain_text(html),
        depth: depth,
        parent_id: parent_id,
        children: []
      )

      block.children.concat(
        child_blocks(html, region.type, counter: counter, depth: depth + 1, parent_id: id)
      )
      block
    end

    # List items and table rows become child blocks, so a reviewer can comment
    # on one bullet or one row. Nested lists recurse.
    def child_blocks(parent_html, parent_type, counter:, depth:, parent_id:)
      tags = CHILD_TAGS[parent_type]
      return [] if tags.nil?

      extract_children(Nokogiri::HTML5.fragment(parent_html), tags,
                       counter: counter, depth: depth, parent_id: parent_id)
    end

    # The first matching element down each DOM branch is a child at this depth;
    # matching elements inside it are that child's own children.
    def extract_children(node, tags, counter:, depth:, parent_id:)
      node.element_children.flat_map do |element|
        unless tags.include?(element.name)
          next extract_children(element, tags, counter: counter, depth: depth,
                                              parent_id: parent_id)
        end

        range = sourcepos_range(element)
        next [] if range.nil?

        # Already sanitized: this element was cut out of the parent's sanitized
        # HTML. Re-sanitizing would *destroy* it, because a bare <tr> or <li>
        # outside its table or list is an orphan that HTML5 fragment parsing
        # drops on the floor.
        html = element.to_html.html_safe
        id = block_id(counter.next, range.first, range.last, html)
        child = Block.new(
          id: id,
          type: CHILD_TYPES.fetch(element.name),
          start_line: range.first,
          end_line: range.last,
          html: html,
          plain_text: plain_text(html),
          depth: depth,
          parent_id: parent_id,
          children: []
        )
        child.children.concat(
          extract_children(element, tags, counter: counter, depth: depth + 1,
                                         parent_id: id)
        )
        [ child ]
      end
    end

    # The rendered attribute carries the same end-column-0 bleed as the AST, so
    # it gets the same clamp.
    def sourcepos_range(element)
      match = element["data-sourcepos"]&.match(SOURCEPOS)
      return nil if match.nil?

      first = match[1].to_i
      last = match[3].to_i
      last -= 1 if match[4].to_i.zero? && last > first
      [ first, [ last, first ].max ]
    end

    # --- identity & text ----------------------------------------------------

    # Stable across renders of identical content, and distinct for every block
    # in a document, so Turbo Frame ids do not collide.
    def block_id(index, first, last, html)
      "b#{index}-#{first}-#{last}-#{Digest::SHA256.hexdigest(html.to_s)[0, 8]}"
    end

    def plain_text(html)
      Nokogiri::HTML5.fragment(html.to_s).text.gsub(/\s+/, " ").strip
    end

    class Counter
      def initialize = @value = -1
      def next = (@value += 1)
    end
  end
end
