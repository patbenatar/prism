# frozen_string_literal: true

require "test_helper"

# The DOM half of the image fix. The resolver here is a stub, because what a
# `src` *means* is Review::RepoImages' problem and is tested there; this is
# about finding every URL in a block and putting the answer back without
# damaging anything else.
class Markdown::ImageRewriterTest < ActiveSupport::TestCase
  # Rewrites anything ending .png, leaves everything else alone — enough to
  # exercise both branches of the resolver contract.
  RESOLVE = ->(src) { src.to_s.end_with?(".png") ? "/proxy/#{src}" : nil }

  def rewrite(html, resolve = RESOLVE)
    Markdown::ImageRewriter.new(resolve).call(html.html_safe)
  end

  test "rewrites an img src" do
    assert_equal %(<p><img src="/proxy/chart.png" alt="Chart"></p>),
                 rewrite(%(<p><img src="chart.png" alt="Chart"></p>))
  end

  test "leaves a src the resolver declines" do
    html = %(<p><img src="https://example.com/x.gif" alt="x"></p>)

    assert_equal html, rewrite(html)
  end

  test "returns a SafeBuffer either way" do
    assert_predicate rewrite(%(<p><img src="a.png"></p>)), :html_safe?
    assert_predicate rewrite(%(<p>no images here</p>)), :html_safe?
  end

  # The cheap guard exists so a document of prose is not re-parsed paragraph by
  # paragraph. Asserted through a side effect rather than a stub: an unescaped
  # `&` is something an HTML5 round trip would normalize to `&amp;`, so getting
  # it back untouched is proof the fragment was never parsed.
  test "skips the parse when the block has no image in it" do
    html = %(<p>A paragraph mentioning img and source & containing neither.</p>)

    assert_equal html, rewrite(html)
  end

  test "finds a self-closing img" do
    assert_equal %(<p><img src="/proxy/a.png"></p>), rewrite(%(<p><img src="a.png"/></p>))
  end

  # GitHub's documented light/dark idiom. The <img> is only the fallback; the
  # <source> is what a dark-mode browser actually loads, so missing it would
  # leave the bug in place for exactly the readers who hit it.
  test "rewrites every candidate in a picture's srcset" do
    html = <<~HTML.strip
      <picture><source media="(prefers-color-scheme: dark)" srcset="dark.png 1x, dark@2x.png 2x"><img src="light.png"></picture>
    HTML

    rewritten = rewrite(html)

    assert_includes rewritten, %(srcset="/proxy/dark.png 1x, /proxy/dark@2x.png 2x")
    assert_includes rewritten, %(src="/proxy/light.png")
    assert_includes rewritten, %(media="(prefers-color-scheme: dark)")
  end

  test "keeps the candidates the resolver declines inside a srcset it changed" do
    rewritten = rewrite(%(<img srcset="a.png 1x, https://cdn.example/b.gif 2x">))

    assert_includes rewritten, %(srcset="/proxy/a.png 1x, https://cdn.example/b.gif 2x")
  end

  test "leaves a srcset holding a data URI alone, commas and all" do
    html = %(<img srcset="data:image/gif;base64,R0lGOD 1x, b.png 2x">)

    assert_equal html, rewrite(html)
  end

  # A node carrying both must not have its srcset skipped because its src
  # already matched, which is what `||` between the two would do.
  test "rewrites src and srcset on the same node" do
    rewritten = rewrite(%(<img src="a.png" srcset="b.png 2x">))

    assert_includes rewritten, %(src="/proxy/a.png")
    assert_includes rewritten, %(srcset="/proxy/b.png 2x")
  end

  test "leaves the rest of the markup untouched" do
    html = %(<p data-sourcepos="1:1-1:9"><a href="/x"><img src="a.png" alt="A" title="T" width="40"></a></p>)
    rewritten = rewrite(html)

    assert_includes rewritten, %(data-sourcepos="1:1-1:9")
    assert_includes rewritten, %(href="/x")
    assert_includes rewritten, %(alt="A")
    assert_includes rewritten, %(title="T")
    assert_includes rewritten, %(width="40")
  end

  test "an img with no src is left alone rather than raising" do
    html = %(<p><img alt="nothing"></p>)

    assert_equal html, rewrite(html)
  end

  test "blank html is returned as it came" do
    assert_equal "", rewrite("")
    assert_nil Markdown::ImageRewriter.new(RESOLVE).call(nil)
  end
end
