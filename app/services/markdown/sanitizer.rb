# frozen_string_literal: true

module Markdown
  # The security boundary for every piece of HTML we render from a repository.
  #
  # Rails' default safelist is far too aggressive for rendered Markdown: it
  # strips tables, task-list inputs, <details>/<summary> and, fatally for us,
  # `data-sourcepos` — the attribute the whole source mapping hangs on. So we
  # supply our own safelist that keeps GitHub-shaped HTML while still removing
  # `style`, event handlers and `javascript:` URLs.
  #
  # Callers pass *untrusted* HTML in and get an `ActiveSupport::SafeBuffer` out.
  # Our own wrapper markup and data attributes are added by the views *after*
  # this, never through it, so they cannot be stripped or spoofed.
  #
  # Ids are namespaced here too. The page targets its own elements by id — Turbo
  # Stream targets, `getElementById` — so a repository file containing
  # `<div id="pending_tray">` would otherwise hijack them. Every surviving id is
  # rewritten to `user-content-…`, the same defence GitHub uses, and
  # same-document fragment links are rewritten to match so heading anchors and
  # footnotes keep working. `name` is not on the safelist, so it is not a second
  # route to the same collision.
  #
  # `media` is on the attribute list for one idiom and carries no risk: GitHub
  # documents `<picture><source media="(prefers-color-scheme: dark)" …>` as the
  # way to ship a light and a dark version of a diagram, and stripping it left
  # every browser taking whichever source came first. A media query only
  # selects between images Prism has already resolved; it cannot name a URL or
  # run anything.
  module Sanitizer
    TAGS = %w[
      h1 h2 h3 h4 h5 h6 p br hr blockquote pre code span div
      ul ol li dl dt dd table thead tbody tfoot tr th td caption
      a img picture source figure figcaption
      strong b em i del ins s sup sub kbd samp var abbr mark small q cite
      details summary section article aside input
    ].freeze

    # `style` is deliberately absent and must stay that way.
    ATTRIBUTES = %w[
      href src alt title id class align width height loading decoding
      type checked disabled start reversed value colspan rowspan scope
      lang dir role rel srcset sizes media open cite
      data-sourcepos data-math-style data-footnotes data-footnote-ref
      data-footnote-backref data-footnote-backref-idx data-heading-content
      aria-label aria-hidden
    ].freeze

    ID_PREFIX = "user-content-"

    # Cheap guard so the extra parse only happens when there is something to fix.
    NEEDS_NAMESPACING = /\sid\s*=|href\s*=\s*["']#/i

    class << self
      # @param html [String, nil] untrusted HTML
      # @return [ActiveSupport::SafeBuffer]
      def call(html)
        return ActiveSupport::SafeBuffer.new if html.blank?

        clean = sanitizer.sanitize(html, tags: TAGS, attributes: ATTRIBUTES).to_s
        namespace_ids(clean).html_safe
      end

      private

      def sanitizer
        @sanitizer ||= Rails::HTML5::SafeListSanitizer.new
      end

      # Prefix every id, and every same-document fragment link, so repository
      # content can never collide with the application's own ids. Both sides are
      # rewritten, so a link that resolved before still resolves after.
      def namespace_ids(html)
        return html unless html.match?(NEEDS_NAMESPACING)

        fragment = Nokogiri::HTML5.fragment(html)

        fragment.css("[id]").each { |node| node["id"] = prefix(node["id"]) }

        fragment.css("a[href]").each do |node|
          href = node["href"].to_s
          next unless href.start_with?("#") && href.length > 1

          node["href"] = "##{prefix(href[1..])}"
        end

        fragment.to_html
      end

      def prefix(value)
        value.start_with?(ID_PREFIX) ? value : "#{ID_PREFIX}#{value}"
      end
    end
  end
end
