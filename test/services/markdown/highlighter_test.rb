# frozen_string_literal: true

require "test_helper"

module Markdown
  class HighlighterTest < ActiveSupport::TestCase
    test "highlights a known language and marks the block" do
      html = Highlighter.call('<pre lang="ruby" data-sourcepos="1:1-3:3"><code>def x
end
</code></pre>')

      assert_includes html, "highlight"
      assert_includes html, "<span"
    end

    test "preserves data-sourcepos, which anchoring depends on" do
      html = Highlighter.call('<pre lang="ruby" data-sourcepos="1:1-3:3"><code>x = 1</code></pre>')

      assert_includes html, 'data-sourcepos="1:1-3:3"'
    end

    test "leaves mermaid and math alone for the client to upgrade" do
      %w[mermaid math].each do |lang|
        html = Highlighter.call("<pre lang=\"#{lang}\"><code>graph TD;</code></pre>")

        assert_not_includes html, "highlight"
        assert_includes html, "graph TD;"
      end
    end

    test "leaves an unknown language unhighlighted rather than raising" do
      html = Highlighter.call('<pre lang="not-a-real-language"><code>x</code></pre>')

      assert_not_includes html, "highlight"
      assert_includes html, "x"
    end

    test "leaves a fence with no language alone" do
      html = "<pre><code>plain</code></pre>"

      assert_equal html, Highlighter.call(html)
    end

    test "returns non-code html untouched" do
      html = "<p>no code here</p>"

      assert_equal html, Highlighter.call(html)
    end

    test "handles blank input" do
      assert_equal "", Highlighter.call("")
      assert_nil Highlighter.call(nil)
    end

    test "escapes code content rather than executing it" do
      html = Highlighter.call('<pre lang="ruby"><code>x = "&lt;script&gt;"</code></pre>')

      assert_not_includes html, "<script>"
    end
  end
end
