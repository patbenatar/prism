# frozen_string_literal: true

require "test_helper"

# The promise this file exists to keep: Prism never rewrites a byte of someone
# else's pull request description.
class Webhooks::MarkerBlockTest < ActiveSupport::TestCase
  BLOCK = Webhooks::MarkerBlock

  test "appends a block to text that has none" do
    result = BLOCK.apply("Fixes the install docs.", "Review in Prism")

    assert_equal "Fixes the install docs.\n\n<!-- prism:begin -->\nReview in Prism\n<!-- prism:end -->", result
  end

  test "adds no separator to empty text" do
    assert_equal "<!-- prism:begin -->\nhi\n<!-- prism:end -->", BLOCK.apply("", "hi")
  end

  test "completes a single trailing newline rather than adding two more" do
    assert_equal "Body\n\n<!-- prism:begin -->\nhi\n<!-- prism:end -->", BLOCK.apply("Body\n", "hi")
  end

  test "adds nothing when the text already ends in a paragraph break" do
    assert_equal "Body\n\n<!-- prism:begin -->\nhi\n<!-- prism:end -->", BLOCK.apply("Body\n\n", "hi")
  end

  # The whole point. Everything before and after the markers has to come back
  # byte for byte, including the things a diff won't show you.
  test "replacing a block touches nothing outside the markers" do
    before = "## Why\n\nSome prose with  double spaces\tand a tab.\n\n"
    after = "\n\n---\n\n<!-- someone-elses-tool -->\nkeep me\n\ntrailing   \n"
    original = "#{before}#{BLOCK.wrap('old')}#{after}"

    result = BLOCK.apply(original, "new")

    assert_equal "#{before}#{BLOCK.wrap('new')}#{after}", result
    assert result.start_with?(before), "text before the block changed"
    assert result.end_with?(after), "text after the block changed"
  end

  test "replaces in place when the author moved the block into the middle" do
    original = "Top\n\n#{BLOCK.wrap('old')}\n\nBottom"

    assert_equal "Top\n\n#{BLOCK.wrap('new')}\n\nBottom", BLOCK.apply(original, "new")
  end

  test "applying the same content twice is a no-op" do
    once = BLOCK.apply("Body", "same")

    assert_equal once, BLOCK.apply(once, "same")
  end

  test "removing takes out the block and nothing else" do
    original = "Top\n\n#{BLOCK.wrap('x')}\n\nBottom"

    assert_equal "Top\n\n\n\nBottom", BLOCK.remove(original)
  end

  test "removing text with no block returns it unchanged" do
    assert_equal "Nothing here", BLOCK.remove("Nothing here")
  end

  # Add, remove, add, remove … must not grow the description a little each
  # time. It settles after the first cycle and then repeats exactly.
  test "add and remove cycles converge instead of accumulating whitespace" do
    body = "Original body."

    added = BLOCK.apply(body, "link")
    removed = BLOCK.remove(added)
    added_again = BLOCK.apply(removed, "link")
    removed_again = BLOCK.remove(added_again)

    assert_equal "Original body.\n\n", removed
    assert_equal added, added_again, "the second add produced different text from the first"
    assert_equal removed, removed_again, "the second remove produced different text from the first"
  end

  # The block Prism actually writes opens with a horizontal rule, so the rule
  # is inside the markers and goes away with them. A rule written outside
  # would survive every retraction and pile up in the author's description.
  test "a leading horizontal rule lives inside the markers and leaves with them" do
    body = "Author's own words."
    content = "---\n\nThe link."

    added = BLOCK.apply(body, content)

    assert BLOCK.content_of(added).start_with?("---"), "the rule must be inside the markers"
    assert_equal "Author's own words.\n\n", BLOCK.remove(added)
    assert_not_includes BLOCK.remove(added), "---"
  end

  test "add and remove cycles with a rule still converge" do
    body = "Original body."
    content = "---\n\nThe link."

    added = BLOCK.apply(body, content)
    removed = BLOCK.remove(added)
    added_again = BLOCK.apply(removed, content)
    removed_again = BLOCK.remove(added_again)

    assert_equal added, added_again, "the second add produced different text from the first"
    assert_equal removed, removed_again, "the second remove produced different text from the first"
    assert_equal 1, added.scan("---").size, "a rule accumulated across the cycle"
  end

  # A rule directly under a paragraph is a setext heading, not a thematic
  # break. Ours is under the HTML comment marker, which closes its own block,
  # so it stays a rule — and the marker is always preceded by a blank line.
  test "the rule is never glued to the author's last paragraph" do
    added = BLOCK.apply("A paragraph.", "---\n\nThe link.")

    assert_includes added, "A paragraph.\n\n#{BLOCK::BEGIN_MARKER}\n---"
  end

  test "reads back the content between the markers" do
    assert_equal "the link", BLOCK.content_of(BLOCK.apply("Body", "the link"))
    assert_nil BLOCK.content_of("Body with no block")
  end

  # A half-deleted block is not a block. Guessing where it ends would mean
  # eating the author's text, so we leave it alone and append a fresh one.
  test "treats an unterminated marker as no block at all" do
    mangled = "Body\n\n<!-- prism:begin -->\nhalf a block, no end marker"

    assert_not BLOCK.present_in?(mangled)
    assert_equal mangled, BLOCK.remove(mangled)
    assert BLOCK.apply(mangled, "link").start_with?(mangled)
  end

  test "an end marker on its own is not a block" do
    assert_not BLOCK.present_in?("Body\n\n<!-- prism:end -->")
  end

  test "matches the first complete block when the markers repeat" do
    text = "#{BLOCK.wrap('first')}\n\n#{BLOCK.wrap('second')}"

    assert_equal "first", BLOCK.content_of(text)
    assert_equal "#{BLOCK.wrap('new')}\n\n#{BLOCK.wrap('second')}", BLOCK.apply(text, "new")
  end

  test "handles CRLF descriptions without mangling the line endings" do
    original = "Line one\r\nLine two\r\n\r\n#{BLOCK.wrap('old')}"

    assert_equal "Line one\r\nLine two\r\n\r\n#{BLOCK.wrap('new')}", BLOCK.apply(original, "new")
  end

  test "content is stripped so the block is stable whatever the caller passes" do
    assert_equal BLOCK.apply("Body", "link"), BLOCK.apply("Body", "\n  link  \n")
  end
end
