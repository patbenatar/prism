# frozen_string_literal: true

require "test_helper"

module Markdown
  # Golden tests that pin comrak's source positions.
  #
  # comrak's sourcepos has changed across releases (its own docs warn that list
  # items are unreliable), so a `bundle update` must not be able to silently
  # break comment anchoring. Each fixture's `.expected` file records the block
  # tree as "type start..end", indented by depth.
  class RendererTest < ActiveSupport::TestCase
    FIXTURES = Rails.root.join("test/fixtures/markdown")

    Dir[FIXTURES.join("*.md")].sort.each do |path|
      name = File.basename(path, ".md")

      test "block ranges for #{name}" do
        expected = File.read(path.sub(/\.md\z/, ".expected"))
        assert_equal expected.strip, outline(File.read(path)), <<~MESSAGE
          Source positions for #{name}.md changed.

          If this is an intentional renderer change, update the .expected file.
          If it followed a gem upgrade, comrak's sourcepos moved and the anchor
          mapping needs re-checking before you accept it.
        MESSAGE
      end

      test "invariants hold for #{name}" do
        assert_invariants Document.parse(File.read(path)), File.read(path)
      end
    end

    # --- normalization ------------------------------------------------------

    test "CRLF line endings do not shift line numbers" do
      assert_equal outline("line one\n\nline two\n"), outline("line one\r\n\r\nline two\r\n")
    end

    test "a BOM does not shift line numbers" do
      assert_equal outline("para one\n\npara two\n"), outline("﻿para one\n\npara two\n")
    end

    test "a BOM is not rendered into the output" do
      blocks = Renderer.new.call("﻿para one\n")
      assert_not_includes blocks.first.html, "﻿"
      assert_equal "para one", blocks.first.plain_text
    end

    test "a missing trailing newline does not shift line numbers" do
      assert_equal outline("para one\n\npara two\n"), outline("para one\n\npara two")
    end

    test "empty and blank input produce no blocks" do
      assert_empty Renderer.new.call("")
      assert_empty Renderer.new.call(nil)
      assert_empty Renderer.new.call("\n\n\n")
    end

    # --- the comrak quirks we normalize -------------------------------------

    test "the last item of a tight list does not bleed onto the following line" do
      # comrak reports this item as ending at 5:0, i.e. the blank line after it.
      blocks = Renderer.new.call("Intro.\n\n- a\n- b\n\nOutro.\n")
      list = blocks.find { |block| block.type == :list }

      assert_equal 3..4, list.range
      assert_equal 4, list.children.last.end_line
    end

    test "a fenced code block range includes its closing fence" do
      block = Renderer.new.call("```ruby\nx = 1\n```\n").first

      assert_equal :code_block, block.type
      assert_equal 1..3, block.range
    end

    test "a setext heading range includes its underline" do
      block = Renderer.new.call("Title\n=====\n").first

      assert_equal :heading, block.type
      assert_equal 1..2, block.range
    end

    # --- raw HTML regions ---------------------------------------------------

    test "details wrapping markdown becomes one html_region, not three blocks" do
      blocks = Renderer.new.call(File.read(FIXTURES.join("details_wrapping_markdown.md")))
      region = blocks.find { |block| block.type == :html_region }

      assert_equal 3..8, region.range
      assert_includes region.html, "<details>"
      assert_includes region.html, "</details>"
      assert_includes region.html, "<em"
    end

    test "balanced raw html stays its own block and absorbs nothing" do
      # Each of these is self-contained but gets *normalized* by an HTML parser
      # (quotes added, tag cased, void element closed). A round-trip comparison
      # mistook that for an unclosed tag and swallowed the following paragraph.
      {
        "unquoted attributes" => "<img src=x alt=y>",
        "uppercase tags" => "<DIV>hi</DIV>",
        "self-closing" => '<img src="x" />',
        "boolean attribute" => '<input type="checkbox" checked>',
        "html comment" => "<!-- note -->",
        "balanced div" => '<div class="a">text</div>'
      }.each do |label, html|
        blocks = Renderer.new.call("#{html}\n\npara after\n")

        assert_equal 2, blocks.size, "#{label} absorbed the following block"
        assert_equal :paragraph, blocks.last.type
        assert_equal 3..3, blocks.last.range
      end
    end

    test "genuinely unclosed html starts a region" do
      blocks = Renderer.new.call("<div class=\"a\">\n\npara after\n")

      assert_equal 1, blocks.size
      assert_equal :html_region, blocks.first.type
    end

    test "an unclosed html block stops absorbing at the node cap" do
      source = "<div>\n\n" + Array.new(60) { |i| "para #{i}\n" }.join("\n")
      blocks = Renderer.new.call(source)
      region = blocks.first

      assert_equal :html_region, region.type
      assert_operator blocks.size, :>, 1,
        "a stray <div> swallowed the whole document instead of hitting the cap"
      assert_operator region.line_count, :<=, Renderer::MAX_HTML_REGION_LINES
    end

    test "an unclosed html block stops absorbing at the line cap" do
      long = Array.new(30) { |i| "para #{i}\n\n" }.join
      blocks = Renderer.new.call("<div>\n\n#{long}")

      assert_operator blocks.size, :>, 1
      assert_operator blocks.first.line_count, :<=, Renderer::MAX_HTML_REGION_LINES
    end

    # --- children -----------------------------------------------------------

    test "table rows become child blocks and skip the delimiter row" do
      table = Renderer.new.call(File.read(FIXTURES.join("table.md"))).first

      assert_equal :table, table.type
      assert_equal [ :table_row ] * 3, table.children.map(&:type)
      assert_equal [ 1, 3, 4 ], table.children.map(&:start_line)
    end

    test "a table row child keeps its cells" do
      row = Renderer.new.call(File.read(FIXTURES.join("table.md"))).first.children.last

      assert_includes row.html, "<tr"
      assert_includes row.html, "r2a"
    end

    test "nested list items nest as child blocks" do
      list = Renderer.new.call(File.read(FIXTURES.join("nested_list.md"))).first
      outer = list.children[1]

      assert_equal 2..4, outer.range
      assert_equal [ 3, 4 ], outer.children.map(&:start_line)
      assert_equal 2, outer.children.first.depth
      assert_equal outer.id, outer.children.first.parent_id
    end

    test "block ids are stable across renders and unique within a document" do
      source = File.read(FIXTURES.join("nested_list.md"))
      first = Renderer.new.call(source).flat_map(&:self_and_descendants).map(&:id)
      second = Renderer.new.call(source).flat_map(&:self_and_descendants).map(&:id)

      assert_equal first, second
      assert_equal first.uniq, first
    end

    # --- output contract ----------------------------------------------------

    test "block html is a SafeBuffer" do
      assert_instance_of ActiveSupport::SafeBuffer, Renderer.new.call("hi\n").first.html
    end

    test "soft line breaks do not become br tags, as in GitHub .md files" do
      block = Renderer.new.call("line one\nline two\n").first

      assert_not_includes block.html, "<br"
    end

    test "two trailing spaces still force a hard break" do
      block = Renderer.new.call("line one  \nline two\n").first

      assert_includes block.html, "<br"
    end

    test "front matter renders as a collapsed metadata table" do
      block = Renderer.new.call(File.read(FIXTURES.join("front_matter.md"))).first

      assert_equal :frontmatter, block.type
      assert_equal 1..4, block.range
      assert_includes block.html, "<details"
      assert_includes block.html, "Front matter"
      assert_includes block.html, "title"
      assert_includes block.html, "docs"
    end

    test "non key-value front matter falls back to preformatted text" do
      block = Renderer.new.call("---\n- just\n- a list\n---\n\nbody\n").first

      assert_equal :frontmatter, block.type
      assert_includes block.html, "<pre"
    end

    test "front matter content is escaped, not interpreted as html" do
      block = Renderer.new.call("---\ntitle: <img src=x onerror=alert(1)>\n---\n\nbody\n").first
      dom = Nokogiri::HTML5.fragment(block.html)

      # The text survives verbatim, but as text: no element is created from it.
      assert_empty dom.css("img")
      assert_includes block.html, "&lt;img"
      assert_equal "<img src=x onerror=alert(1)>", dom.css("td").text
    end

    test "a mermaid block is left as a pre for the client to upgrade" do
      block = Renderer.new.call(File.read(FIXTURES.join("mermaid.md"))).last

      assert_includes block.html, "<pre"
      assert_includes block.html, "mermaid"
      assert_includes block.html, "graph TD"
    end

    test "math carries its display style for the client to upgrade" do
      blocks = Renderer.new.call(File.read(FIXTURES.join("math.md")))

      assert_includes blocks.first.html, 'data-math-style="inline"'
      assert_includes blocks[1].html, 'data-math-style="display"'
    end

    test "plain_text strips markup for quoting" do
      block = Renderer.new.call("Some **bold** and `code` text.\n").first

      assert_equal "Some bold and code text.", block.plain_text
    end

    # --- id namespacing through the full pipeline ---------------------------

    test "a repository file cannot hijack an application id" do
      blocks = Renderer.new.call("<div id=\"pending_tray\">hijack</div>\n")

      assert_includes blocks.first.html, 'id="user-content-pending_tray"'
      assert_not_includes blocks.first.html, 'id="pending_tray"'
    end

    test "heading anchors resolve after namespacing" do
      block = Renderer.new.call("# My Heading\n").first

      assert_includes block.html, 'id="user-content-my-heading"'
      assert_includes block.html, 'href="#user-content-my-heading"'
    end

    test "a markdown link to a heading still resolves" do
      blocks = Renderer.new.call("# My Heading\n\n[go](#my-heading)\n")

      assert_includes blocks.first.html, 'id="user-content-my-heading"'
      assert_includes blocks.last.html, 'href="#user-content-my-heading"'
    end

    test "footnote links and back-references still resolve" do
      blocks = Renderer.new.call("Text[^1].\n\n[^1]: The note.\n")
      reference = blocks.first.html
      definition = blocks.last.html

      assert_includes reference, 'href="#user-content-fn-1"'
      assert_includes reference, 'id="user-content-fnref-1"'
      assert_includes definition, 'id="user-content-fn-1"'
      assert_includes definition, 'href="#user-content-fnref-1"'
    end

    test "child extraction matches on data-sourcepos, not on id" do
      # Ids move under namespacing; source positions do not. Children must key
      # off the position attribute so prefixing can never break the tree.
      list = Renderer.new.call("- one\n- two\n").first

      assert_equal 2, list.children.size
      assert_equal [ 1, 2 ], list.children.map(&:start_line)
    end

    private

    def outline(source)
      Document.parse(source).all_blocks
              .map { |block| "#{'  ' * block.depth}#{block.type} #{block.start_line}..#{block.end_line}" }
              .join("\n")
    end

    # The invariant that would have caught comrak's list-item bleed on its own.
    def assert_invariants(document, source)
      line_count = source.gsub("\r\n", "\n").lines.size

      document.blocks.each_cons(2) do |before, after|
        assert_operator before.end_line, :<, after.start_line,
          "top-level blocks overlap: #{before.type} #{before.range} then #{after.type} #{after.range}"
      end

      document.all_blocks.each do |block|
        assert_operator block.start_line, :>=, 1, "#{block.type} starts before the file"
        assert_operator block.start_line, :<=, block.end_line, "#{block.type} has an inverted range"
        assert_operator block.end_line, :<=, line_count, "#{block.type} ends past the file"
      end

      document.all_blocks.each do |parent|
        parent.children.each do |child|
          assert_operator parent.start_line, :<=, child.start_line, "child starts before its parent"
          assert_operator child.end_line, :<=, parent.end_line, "child ends after its parent"
          assert_equal parent.id, child.parent_id
          assert_equal parent.depth + 1, child.depth
        end
      end
    end
  end
end
