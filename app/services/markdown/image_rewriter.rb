# frozen_string_literal: true

module Markdown
  # Points the images in a rendered block at somewhere the browser can actually
  # reach them.
  #
  # A Markdown image is nearly always written relative to the file that carries
  # it — `![chart](chart.png)`, `![logo](./img/logo.svg)`, `![shared](../img.png)`
  # — and comrak emits that destination verbatim. Dropped into a Prism page at
  # `/acme/docs/pulls/42/markdown`, the browser resolves it against *us* and
  # gets a 404, which is the whole of the "broken image" bug. It has to become a
  # URL that names the blob in the repository, at the ref we rendered.
  #
  # This class only walks the DOM; every decision about what a `src` means
  # belongs to the resolver it is given (`Review::RepoImages`), which knows the
  # repository, the ref and the directory the document lives in. That keeps
  # `Markdown::*` free of Rails and of GitHub, and it is what lets the path
  # rules be unit-tested on their own.
  #
  # **This runs after Markdown::Sanitizer, never through it.** The safelist has
  # already decided which tags and attributes survive; we then rewrite the value
  # of attributes it kept. Rewriting first would mean handing the sanitizer
  # URLs we generated and hoping they came back, and re-sanitizing after would
  # be a second pass over HTML that is already safe.
  class ImageRewriter
    # Cheap guard. Most blocks in a document have no image in them at all, and
    # re-parsing every paragraph to discover that would cost more than the
    # rewrite saves — the same reason Highlighter checks for "<pre" first.
    CONTAINS_IMAGE = %r{<(?:img|source)[\s/>]}i

    # `<picture>` and `<source>` are both on the sanitizer's safelist, and the
    # dark-mode idiom GitHub documents uses them:
    #
    #   <picture>
    #     <source media="(prefers-color-scheme: dark)" srcset="dark.png">
    #     <img src="light.png" alt="…">
    #   </picture>
    #
    # so a rewriter that only looked at `img[src]` would fix the fallback and
    # leave the image actually shown in dark mode broken.
    NODES = "img, source"

    # A srcset is "url descriptor, url descriptor" — and a `data:` URI can
    # contain the comma that separates them, which would make a naive split
    # corrupt it. We never rewrite a data: URI anyway, so the safe answer is to
    # leave any srcset containing one entirely alone.
    DATA_URI = /(?:\A|,)\s*data:/i

    # @param resolve [#call] `src` in, a replacement URL out, or nil to leave it.
    def initialize(resolve)
      @resolve = resolve
    end

    # @param html [ActiveSupport::SafeBuffer] sanitized block HTML
    # @return [ActiveSupport::SafeBuffer]
    def call(html)
      return html if html.blank? || !html.match?(CONTAINS_IMAGE)

      fragment = Nokogiri::HTML5.fragment(html)
      # `count` rather than `any?`: every node has to be visited, and `any?`
      # stops at the first one that changed.
      changed = fragment.css(NODES).count { |node| rewrite(node) }.positive?

      changed ? fragment.to_html.html_safe : html
    end

    private

    def rewrite(node)
      # Both, always — `|` and not `||`, so a node carrying src *and* srcset
      # does not have its srcset skipped because its src already matched.
      rewrite_src(node) | rewrite_srcset(node)
    end

    def rewrite_src(node)
      replacement = @resolve.call(node["src"])
      return false if replacement.nil?

      node["src"] = replacement
      true
    end

    def rewrite_srcset(node)
      value = node["srcset"]
      return false if value.blank? || value.match?(DATA_URI)

      changed = false
      candidates = value.split(",").map do |candidate|
        url, descriptor = candidate.strip.split(/\s+/, 2)
        replacement = url.blank? ? nil : @resolve.call(url)
        next candidate.strip if replacement.nil?

        changed = true
        [ replacement, descriptor ].compact.join(" ")
      end

      node["srcset"] = candidates.join(", ") if changed
      changed
    end
  end
end
