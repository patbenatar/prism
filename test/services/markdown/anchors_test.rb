# frozen_string_literal: true

require "test_helper"

module Markdown
  # Section links through the real pipeline — comrak, the sanitizer, then
  # Anchors — because what matters is what a page ends up holding, and the
  # numbering in particular only exists across blocks.
  class AnchorsTest < ActiveSupport::TestCase
    SCOPE = "f-0123456789"
    PATH = "docs/guide.md"

    # --- numbering, the way GitHub numbers ----------------------------------

    test "duplicate headings are numbered across the document, as GitHub numbers them" do
      ids = heading_ids("## Setup\n\nText.\n\n## Setup\n\n## Setup\n")

      assert_equal %w[user-content-setup user-content-setup-1 user-content-setup-2], ids
    end

    test "a heading whose own slug is taken by a numbered one is numbered again" do
      # comrak's rule: "Setup 1" would be `setup-1`, which the second "Setup"
      # already holds, so it becomes `setup-1-1` rather than sharing an id.
      ids = heading_ids("## Setup\n\n## Setup\n\n## Setup 1\n")

      assert_equal %w[user-content-setup user-content-setup-1 user-content-setup-1-1], ids
    end

    test "headings inside one block keep counting from the ones before it" do
      # A blockquote is one block, and comrak has already numbered within it;
      # the document-wide count has to win, or the two would restart at -1.
      ids = heading_ids("## Setup\n\n> ## Setup\n> ## Setup\n")

      assert_equal %w[user-content-setup user-content-setup-1 user-content-setup-2], ids
    end

    test "the slug is comrak's, punctuation, case and non-English letters included" do
      [ "Hello, World!", "Über & `code` *em*", "  Spaced   out  ", "snake_case and-dash", "100% done?" ].each do |text|
        expected = Commonmarker.to_html("# #{text}\n", options: { extension: { header_ids: "" } })[/id="([^"]*)"/, 1]

        assert_equal expected, Anchors.slug(Nokogiri::HTML5.fragment(Commonmarker.to_html("# #{text}\n")).text.strip),
                     "slug for #{text.inspect}"
      end
    end

    test "a table of contents link to a numbered heading lands on that heading" do
      blocks = render("- [Second setup](#setup-1)\n\n## Setup\n\n## Setup\n")

      link = Nokogiri::HTML5.fragment(blocks.first.html).at_css("a")
      second = Nokogiri::HTML5.fragment(blocks.last.html).at_css("h2")

      assert_equal "##{PATH}:setup-1", link["href"]
      assert_equal "user-content-#{SCOPE}-setup-1", second["id"]
    end

    # --- scoping ------------------------------------------------------------

    test "every id is scoped to its file, and no file's ids can reach another's" do
      source = "# Overview\n\nText[^1].\n\n<div id=\"note\">n</div>\n\n[^1]: A note.\n"

      one = all_ids(render(source, scope: "f-aaaaaaaaaa", path: "a.md"))
      two = all_ids(render(source, scope: "f-bbbbbbbbbb", path: "b.md"))

      assert one.all? { |id| id.start_with?("user-content-f-aaaaaaaaaa-") }, one.inspect
      assert two.all? { |id| id.start_with?("user-content-f-bbbbbbbbbb-") }, two.inspect
      assert_empty one & two, "two files with the same headings must not share an id"
    end

    test "scoping does not undo the sanitizer: an app id is still unreachable" do
      html = render("<div id=\"pending_tray\">hijack</div>\n").first.html

      assert_includes html, %(id="user-content-#{SCOPE}-pending_tray")
      assert_not_includes html, 'id="pending_tray"'
    end

    test "footnotes resolve inside their own file" do
      blocks = render("Text[^1].\n\n[^1]: The note.\n")
      reference = Nokogiri::HTML5.fragment(blocks.first.html).at_css("a")
      definition = Nokogiri::HTML5.fragment(blocks.last.html).at_css("li")

      assert_equal "##{PATH}:fn-1", reference["href"]
      assert_equal "user-content-#{SCOPE}-fn-1", definition["id"]
    end

    test "an author's raw-HTML heading keeps its own id and gets no link" do
      html = render("## Setup\n\n<h2 id=\"setup\">Raw</h2>\n").last.html
      heading = Nokogiri::HTML5.fragment(html).at_css("h2")

      # Scoped like every id, not numbered, because the author chose it.
      assert_equal "user-content-#{SCOPE}-setup", heading["id"]
      assert_nil heading.at_css("a")
    end

    # --- the link a reader shares -------------------------------------------

    test "a heading's link is a real link to its section, named for the reader" do
      link = heading_link(render("## Getting started\n").first.html)

      assert_equal "##{PATH}:getting-started", link["href"]
      assert_equal "false", link["data-turbo"], "Turbo must not turn a same-page link into a visit"
      assert_equal "Link to heading 'Getting started'", link["aria-label"]
      assert_includes link["class"], "md-heading-link"
      assert_equal "true", link.at_css("svg")["aria-hidden"]
      assert_not_includes link["href"], "user-content"
    end

    test "the link comes after the heading's text, clear of the gutter" do
      heading = Nokogiri::HTML5.fragment(render("## Setup\n").first.html).at_css("h2")

      assert_equal "a", heading.element_children.last.name
      assert_equal "Setup", heading.children.first.text
    end

    test "a path or heading the URL cannot carry as written is percent-encoded once" do
      blocks = render("## Über uns\n\n[x](#über-uns)\n", path: "docs/read me#1.md")

      assert_equal "#docs/read%20me%231.md:%C3%BCber-uns", heading_link(blocks.first.html)["href"]
      # comrak had already encoded the author's link; it must not be encoded twice.
      assert_equal "#docs/read%20me%231.md:%C3%BCber-uns",
                   Nokogiri::HTML5.fragment(blocks.last.html).at_css("a")["href"]
    end

    test "every same-document link opts out of Turbo, and other links are left alone" do
      html = render("[in](#setup) [out](https://example.com) [rel](other.md)\n").first.html
      links = Nokogiri::HTML5.fragment(html).css("a")

      assert_equal [ "false", nil, nil ], links.map { |link| link["data-turbo"] }
      assert_equal [ "https://example.com", "other.md" ], links.drop(1).map { |link| link["href"] }
    end

    # --- the removed side ---------------------------------------------------

    test "a removed strip's headings get no link, and its links go straight to their ids" do
      anchors = Anchors.new(scope: "b-0123456789", linkable: false)
      blocks = Renderer.new(anchors: anchors).call("[top](#old)\n\n## Old\n")

      heading = Nokogiri::HTML5.fragment(blocks.last.html).at_css("h2")
      link = Nokogiri::HTML5.fragment(blocks.first.html).at_css("a")

      assert_nil heading.at_css("a"), "a deleted section is nothing to share"
      assert_equal "user-content-b-0123456789-old", heading["id"]
      assert_equal "#user-content-b-0123456789-old", link["href"]
    end

    test "a document rendered on its own keeps GitHub's plain ids" do
      html = Renderer.new.call("# My Heading\n").first.html

      assert_includes html, 'id="user-content-my-heading"'
      assert_includes html, 'href="#user-content-my-heading"'
    end

    test "the scope and path are what the parse cache keys on" do
      assert_not_equal Anchors.new(scope: "f-1", path: "a.md").cache_key,
                       Anchors.new(scope: "f-1", path: "b.md").cache_key
      assert_not_equal Anchors.new(scope: "f-1").cache_key,
                       Anchors.new(scope: "b-1", linkable: false).cache_key
    end

    private

    def render(source, scope: SCOPE, path: PATH)
      Renderer.new(anchors: Anchors.new(scope: scope, path: path)).call(source)
    end

    def heading_ids(source)
      Renderer.new.call(source).flat_map do |block|
        Nokogiri::HTML5.fragment(block.html).css("h1, h2, h3, h4, h5, h6").map { |heading| heading["id"] }
      end
    end

    def all_ids(blocks)
      blocks.flat_map { |block| Nokogiri::HTML5.fragment(block.html).css("[id]").map { |node| node["id"] } }
    end

    def heading_link(html) = Nokogiri::HTML5.fragment(html).at_css("a.md-heading-link")
  end
end
