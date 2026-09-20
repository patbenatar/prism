# frozen_string_literal: true

require "test_helper"

# `block_body` weaves the per-child markers into a list's or a table's rendered
# HTML. The hard part is matching a child block to the element it came from,
# because comrak reports positions in lines only — and two list items can start
# on the same line.
class PullRequestFilesHelperTest < ActionView::TestCase
  tests PullRequestFilesHelper

  PATH = "docs/list.md"
  KEY = Review::Page.file_key(PATH)

  # Every id on the page is prefixed with the file's key, because the review
  # screen holds every Markdown file in the pull request at once and the
  # renderer numbers blocks from zero per document.
  def dom_id(child) = "#{KEY}-#{child.block.id}"

  # ----------------------------------------------------------- collisions --

  test "an outer and an inner list item on one line each keep their own block" do
    # Valid CommonMark: one line holding two nested items. Both children report
    # start_line 1, so anything keyed on the line alone loses one of them.
    outer, inner = children_of("- - a\n")
    items = woven("- - a\n").css("li")

    assert_equal 2, items.size
    assert_equal dom_id(outer), items[0]["data-block-id"], "the outer <li> takes the outer block"
    assert_equal dom_id(inner), items[1]["data-block-id"], "the inner <li> takes the inner block"
  end

  test "a list item whose first line already holds a nested item still gets a gutter" do
    fragment = woven("1. - a\n   - b\n")
    items = fragment.css("li")

    assert_equal 3, items.size
    assert_equal children_of("1. - a\n   - b\n").map { |child| dom_id(child) },
                 items.map { |item| item["data-block-id"] }
    assert_equal 3, fragment.css("li > .md-add--child").size,
                 "every item offers its own +, including the one sharing line 1"
  end

  test "colliding start lines never produce the same id twice" do
    assert_unique_ids woven("- - a\n")
    assert_unique_ids woven("1. - a\n   - b\n")
    assert_unique_ids woven("- - - deep\n")
  end

  # ------------------------------------------------------- ordinary cases --

  test "a nested list inside a list item keeps outer and inner apart" do
    outer, inner = children_of("- outer\n  - inner\n")
    items = woven("- outer\n  - inner\n").css("li")

    assert_equal dom_id(outer), items[0]["data-block-id"]
    assert_equal dom_id(inner), items[1]["data-block-id"]
    assert_equal "outer", items[0].at_css("> .md-add--child")&.next_sibling&.text&.strip
  end

  test "each list item carries the two containers the commenting seam targets" do
    fragment = woven("- one\n- two\n")

    children_of("- one\n- two\n").each do |child|
      assert fragment.at_css("li#block_#{dom_id(child)}"), "the item is addressable by id"
      assert fragment.at_css("#threads_#{dom_id(child)}"), "threads container"
      assert fragment.at_css("#composer_#{dom_id(child)}"), "composer slot"
    end
  end

  test "a table row's containers go in an extra row spanning every column" do
    source = "| A | B |\n| --- | --- |\n| 1 | 2 |\n"
    fragment = woven(source)
    rows = fragment.css("tr:not(.md-thread-row)")

    assert_equal 2, rows.size, "the header row is commentable too"
    assert_unique_ids fragment

    rows.each do |row|
      block_id = row["data-block-id"]
      thread_row = fragment.at_css("tr.md-thread-row[data-thread-row-for='#{block_id}']")

      assert thread_row, "row #{block_id} has a thread row"
      assert_equal row.next_element, thread_row, "it follows the row it belongs to"
      assert_equal 2, thread_row.at_css("td")["colspan"].to_i
      assert thread_row.at_css("##{"threads_#{block_id}"}")
      assert thread_row.at_css("##{"composer_#{block_id}"}")
    end

    assert fragment.at_css("table.md-child-table"), "the table reserves room for the row +"
  end

  test "a block with no children is passed through untouched" do
    blocks = annotated("Just a paragraph.\n")

    assert_equal blocks.first.block.html, block_body(blocks.first, pull_request: nil, path: PATH)
  end

  test "two files whose blocks collide still get distinct ids" do
    source = "- one\n"
    child = children_of(source).first
    here = woven(source).at_css("li")["data-block-id"]
    there = Nokogiri::HTML5.fragment(
      block_body(annotated(source).first, pull_request: nil, path: "elsewhere/list.md")
    ).at_css("li")["data-block-id"]

    assert_equal "#{KEY}-#{child.block.id}", here
    assert_not_equal here, there, "the same block in two files must not share an id"
    assert_equal child.block.id, here.delete_prefix("#{KEY}-")
  end

  # -------------------------------------------------------------- the "+" --

  test "an uncommentable child's + is muted and carries the reason in words" do
    # No patch at all, so nothing in the file can take a line comment.
    button = woven("- one\n").at_css(".md-add--child")

    assert_includes button["class"], "md-add--muted"
    assert_equal "no_patch", button["data-uncommentable-reason"]
    assert_nil button["data-anchor"], "there is nothing to anchor to"
    assert_match "didn't provide a diff", button["title"]
  end

  test "a commentable child carries the anchor the composer will post" do
    source = "- one\n- two\n"
    patch = "@@ -1,2 +1,2 @@\n+- one\n+- two"
    button = woven(source, patch: patch).at_css(".md-add--child")
    anchor = JSON.parse(button["data-anchor"])

    assert_equal "true", button["data-commentable"]
    assert_equal PATH, anchor["path"]
    assert_equal "RIGHT", anchor["side"]
    assert_equal 1, anchor["line"]
  end

  private

  def annotated(source, patch: nil)
    blocks = Markdown::Document.parse(source).blocks

    Review::BlockMapper.call(
      head_blocks: blocks, base_blocks: [], line_sets: Diff::Patch.parse(patch),
      threads: [], path: PATH, file_status: "modified"
    ).blocks
  end

  # The child blocks of the first top-level block, in the order the renderer
  # walked them: outermost first, then into each.
  def children_of(source, patch: nil)
    annotated(source, patch: patch).first.children.flat_map(&:self_and_descendants)
  end

  def woven(source, patch: nil)
    Nokogiri::HTML5.fragment(block_body(annotated(source, patch: patch).first,
                                         pull_request: nil, path: PATH))
  end

  def assert_unique_ids(fragment)
    ids = fragment.css("[id]").map { |node| node["id"] }
    assert_equal ids.uniq, ids, "ids must be unique: #{ids.tally.select { |_, n| n > 1 }.keys.inspect}"

    # Only the elements that *host* a block. A gutter button repeats its
    # block's id by design, so it is not a duplicate.
    hosts = fragment.css("li[data-block-id], tr[data-block-id]").map { |node| node["data-block-id"] }
    assert_equal hosts.uniq, hosts, "no two elements may claim the same block"
  end
end
