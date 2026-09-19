# frozen_string_literal: true

require "test_helper"

module Markdown
  class SanitizerTest < ActiveSupport::TestCase
    # --- what must survive --------------------------------------------------

    test "keeps data-sourcepos, without which nothing can be anchored" do
      assert_includes Sanitizer.call('<p data-sourcepos="1:1-1:5">hi</p>'), 'data-sourcepos="1:1-1:5"'
    end

    test "keeps tables" do
      html = Sanitizer.call('<table><thead><tr><th align="right">a</th></tr></thead>' \
                            "<tbody><tr><td>b</td></tr></tbody></table>")

      assert_includes html, "<table>"
      assert_includes html, "<td>"
      assert_includes html, 'align="right"'
    end

    test "keeps task list checkboxes" do
      html = Sanitizer.call('<li><input type="checkbox" checked disabled> done</li>')

      assert_includes html, "<input"
      assert_includes html, "checkbox"
    end

    test "keeps details and summary" do
      html = Sanitizer.call("<details open><summary>s</summary><p>body</p></details>")

      assert_includes html, "<details"
      assert_includes html, "<summary>"
    end

    test "keeps GitHub-flavoured inline markup" do
      html = Sanitizer.call("<sup>a</sup><sub>b</sub><kbd>K</kbd><del>d</del><ins>i</ins><mark>m</mark>")

      %w[sup sub kbd del ins mark].each { |tag| assert_includes html, "<#{tag}>" }
    end

    test "keeps images with alt text and heading ids" do
      html = Sanitizer.call('<h2 id="user-content-x"><img src="/a.png" alt="A" loading="lazy"></h2>')

      assert_includes html, 'id="user-content-x"'
      assert_includes html, 'alt="A"'
    end

    test "keeps rouge token markup" do
      assert_includes Sanitizer.call('<pre class="highlight"><code><span class="k">def</span></code></pre>'),
                      '<span class="k">'
    end

    # --- what must not survive ----------------------------------------------

    test "removes script elements" do
      html = Sanitizer.call("<p>ok</p><script>alert(1)</script>")

      assert_includes html, "<p>ok</p>"
      assert_not_includes html, "<script"
    end

    test "removes event handler attributes" do
      html = Sanitizer.call('<img src="x.png" onerror="alert(1)" alt="a">')

      assert_includes html, "<img"
      assert_not_includes html, "onerror"
    end

    test "removes javascript: urls but keeps the link text" do
      html = Sanitizer.call('<a href="javascript:alert(1)">click</a>')

      assert_not_includes html, "javascript:"
      assert_includes html, "click"
    end

    test "removes style attributes" do
      assert_not_includes Sanitizer.call('<p style="position:fixed;top:0">x</p>'), "style"
    end

    test "removes iframes, objects, forms and svg" do
      html = Sanitizer.call("<iframe src='//evil'></iframe><object></object>" \
                            "<form action='/x'><button>go</button></form><svg><use href='#x'/></svg>")

      %w[<iframe <object <form <svg].each { |tag| assert_not_includes html, tag }
    end

    test "removes data: urls on images" do
      html = Sanitizer.call('<img src="data:text/html;base64,PHNjcmlwdD4=">')

      assert_not_includes html, "data:text/html"
    end

    # --- id namespacing -----------------------------------------------------

    test "namespaces an injected id that would hijack an application target" do
      html = Sanitizer.call('<div id="pending_tray">hijack</div>')

      assert_includes html, 'id="user-content-pending_tray"'
      assert_not_includes html, 'id="pending_tray"'
    end

    test "namespaces every id, not just the first" do
      html = Sanitizer.call('<div id="a"><span id="b">x</span></div>')

      assert_includes html, 'id="user-content-a"'
      assert_includes html, 'id="user-content-b"'
    end

    test "does not double-prefix an id comrak already namespaced" do
      html = Sanitizer.call('<h1 id="user-content-intro">Intro</h1>')

      assert_includes html, 'id="user-content-intro"'
      assert_not_includes html, "user-content-user-content-"
    end

    test "rewrites same-document links so they still resolve" do
      html = Sanitizer.call('<a href="#intro">go</a><p id="intro">x</p>')

      assert_includes html, 'href="#user-content-intro"'
      assert_includes html, 'id="user-content-intro"'
    end

    test "leaves external and relative links alone" do
      html = Sanitizer.call('<a href="https://example.com/#frag">a</a><a href="/docs#x">b</a>')

      assert_includes html, 'href="https://example.com/#frag"'
      assert_includes html, 'href="/docs#x"'
    end

    test "leaves a bare hash href alone" do
      assert_includes Sanitizer.call('<a href="#">x</a>'), 'href="#"'
    end

    test "name is not a second route to an id collision" do
      # `name` is not on the safelist, so it cannot reintroduce the collision
      # that prefixing ids closes.
      html = Sanitizer.call('<a name="pending_tray">x</a>')

      assert_not_includes html, "name="
      assert_not_includes Sanitizer::ATTRIBUTES, "name"
    end

    test "html with no ids or fragments is returned unchanged" do
      html = "<p>plain text</p>"

      assert_equal html, Sanitizer.call(html)
    end

    # --- contract -----------------------------------------------------------

    test "returns a SafeBuffer" do
      assert_instance_of ActiveSupport::SafeBuffer, Sanitizer.call("<p>x</p>")
    end

    test "handles nil and blank input" do
      assert_equal "", Sanitizer.call(nil)
      assert_equal "", Sanitizer.call("")
      assert_instance_of ActiveSupport::SafeBuffer, Sanitizer.call(nil)
    end

    test "is idempotent" do
      once = Sanitizer.call('<p data-sourcepos="1:1-1:2">x</p><script>y</script>')

      assert_equal once, Sanitizer.call(once)
    end
  end
end
