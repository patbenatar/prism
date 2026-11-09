# frozen_string_literal: true

require "set"

module Markdown
  # Section links: the ids a document's headings carry, the links that point at
  # them, and the "#" a reader copies to share one.
  #
  # Three things are wrong with the ids comrak hands us, and this fixes all of
  # them after Markdown::Sanitizer has run, the way ImageRewriter fixes `src`:
  #
  # 1. **Duplicate headings are not numbered.** The renderer turns one AST node
  #    at a time into HTML, and comrak's anchorizer lives for one `to_html`
  #    call, so two `## Setup` headings both come out as `setup`. GitHub calls
  #    the second one `setup-1`, and a table of contents written against
  #    GitHub links to that. A {Pass} keeps the set of slugs for the whole
  #    document and numbers them the way comrak would have.
  #
  # 2. **Ids collide across files.** The Markdown tab holds every file in the
  #    pull request on one page, so two READMEs that both say `## Overview`
  #    both produce `user-content-overview`, and so do their footnotes. Every
  #    id in a document is scoped to its file: `user-content-<scope>-overview`.
  #    The scope is a fixed-length key per file (`Review::Page.file_key`), so
  #    two files' ids differ in their first 26 characters and nothing a
  #    repository writes can make one file's id land in another's.
  #    Markdown::Sanitizer's guarantee is untouched: every id still starts with
  #    `user-content-`, which no id of Prism's own does.
  #
  # 3. **What a reader shares should not say `user-content-`.** GitHub's
  #    address bar reads `#overview` and its JavaScript maps that onto
  #    `#user-content-overview`. Prism's reads `#docs/guide.md:overview` — the
  #    file's path, a colon, and the slug GitHub would have used — and
  #    `controllers/fragments` maps it back. The path is there because the page
  #    holds more than one file; see {.fragment}.
  #
  # Every same-document link gets `data-turbo="false"` for the reason the file
  # switcher's rows do (DESIGN.md §6): Turbo 8 treats a link to the page you
  # are on as a visit, and a visit re-fetches and re-renders the whole review,
  # throwing away an open composer, to move the scroll position.
  class Anchors
    PREFIX = Sanitizer::ID_PREFIX

    HEADINGS = "h1, h2, h3, h4, h5, h6"

    # comrak's own rule for turning a heading into a slug — `anchorize` in
    # comrak's html.rs, which is GitHub's: lowercase, drop everything that is
    # not a letter, mark, number, connector, space or hyphen, then spaces
    # become hyphens. Repeated here only so a duplicate can be renumbered from
    # the heading's text rather than from an id comrak may already have
    # numbered inside one block.
    REJECTED = /[^\p{L}\p{M}\p{N}\p{Pc} -]/

    # Cheap guard, the same trade as ImageRewriter's: most blocks have no id
    # and no fragment link in them, and parsing every paragraph to find that
    # out costs more than the rewrite.
    NEEDS_WORK = /\sid="#{PREFIX}|href="##{PREFIX}/o

    # A heading's link, drawn after its text. Heroicons' 20px "link", inline
    # rather than an <img> so it takes the link's own colour in both schemes.
    ICON = <<~SVG.squish.freeze
      <svg viewBox="0 0 20 20" fill="currentColor" aria-hidden="true" focusable="false">
      <path d="M12.232 4.232a2.5 2.5 0 0 1 3.536 3.536l-1.225 1.224a.75.75 0 0 0 1.061 1.06l1.224-1.224a4 4 0 0 0-5.656-5.656l-3 3a4 4 0 0 0 .225 5.865.75.75 0 0 0 .977-1.138 2.5 2.5 0 0 1-.142-3.667l3-3Z"/>
      <path d="M11.603 7.963a.75.75 0 0 0-.977 1.138 2.5 2.5 0 0 1 .142 3.667l-3 3a2.5 2.5 0 0 1-3.536-3.536l1.225-1.224a.75.75 0 0 0-1.061-1.06l-1.224 1.224a4 4 0 1 0 5.656 5.656l3-3a4 4 0 0 0-.225-5.865Z"/>
      </svg>
    SVG

    # Characters that may stand in a URL fragment as they are (RFC 3986's
    # unreserved set plus the sub-delims and "/" and ":" and "@" a fragment
    # allows). Everything else — a space, "#", "%", "<", a non-ASCII letter —
    # is percent-encoded, so a path or a slug can never end the fragment early
    # or be misread on the way back. The browser shows the decoded form.
    FRAGMENT_SAFE = %r{[^A-Za-z0-9\-._~!$&'()*+,;=:@/]}

    class << self
      # The slug GitHub gives a heading with this text, before any numbering.
      def slug(text) = text.to_s.downcase.gsub(REJECTED, "").tr(" ", "-")

      # What a reader sees and shares for an anchor in the file at `path`:
      # `docs/guide.md:overview`.
      #
      # The path rather than the file's hex key, because a link is something a
      # person reads before they click it, and "the Overview of docs/guide.md"
      # is the whole of what this one says. The colon cannot be confused with
      # either side: a slug never contains one (the rule above drops it), and
      # `controllers/fragments` matches the path against the files actually on
      # the page rather than splitting on it.
      def fragment(path, name)
        "#{encode(path)}:#{encode(name)}"
      end

      def encode(value)
        value.to_s.gsub(FRAGMENT_SAFE) { |char| char.bytes.map { |byte| format("%%%02X", byte) }.join }
      end
    end

    attr_reader :scope, :path

    # @param scope [String, nil] the fixed-length key that makes this file's
    #   ids unique on the page. Nil leaves ids as `user-content-<slug>`, which
    #   is right for a document rendered on its own (the unit tests, a preview).
    # @param path [String, nil] the file the document is. With one, a link
    #   reads `#<path>:<slug>`; without, it keeps pointing at the id itself.
    # @param linkable [Boolean] false for the base side of a modified file,
    #   whose blocks only appear in a removed strip. Those headings were
    #   deleted by the pull request, so they get no link of their own, and
    #   links inside the strip point straight at their scoped ids.
    def initialize(scope: nil, path: nil, linkable: true)
      @scope = scope
      @path = linkable ? path : nil
      @linkable = linkable
    end

    # Part of the parse cache's key (Review::ParsedSource): the same bytes in
    # two files, or on the two sides of one file, render different ids.
    def cache_key = [ scope, path, linkable? ]

    def linkable? = @linkable

    # A fresh {Pass} for one document. The slugs seen so far are per document,
    # so this is called once per render, never shared between two.
    def pass = Pass.new(self)

    # One document's worth of rewriting, fed its blocks in order.
    class Pass
      def initialize(anchors)
        @anchors = anchors
        @seen = Set.new
      end

      # @param html [ActiveSupport::SafeBuffer] one block's sanitized HTML
      # @return [ActiveSupport::SafeBuffer]
      def call(html)
        return html if html.blank? || !html.match?(NEEDS_WORK)

        fragment = Nokogiri::HTML5.fragment(html)

        # Headings first, so the numbering is decided before any id moves.
        fragment.css(HEADINGS).each { |heading| heading_anchor(heading) }
        fragment.css("[id]").each { |node| node["id"] = scoped(node["id"]) }
        fragment.css("a[href]").each { |link| same_document_link(link) }

        fragment.to_html.html_safe
      end

      private

      # Only a heading comrak generated gets numbered and linked: one with
      # `id` and the empty `a.anchor` comrak appends, which carries the
      # heading's text in `data-heading-content`. A raw-HTML `<h2 id="x">` is
      # the author's own id and is left alone, as GitHub leaves it.
      def heading_anchor(heading)
        link = heading.at_css("a.anchor[data-heading-content]")
        return if link.nil? || !heading["id"].to_s.start_with?(PREFIX)

        slug = unique(Anchors.slug(link["data-heading-content"]))
        heading["id"] = "#{PREFIX}#{slug}"
        # Only the slug: `same_document_link` below turns this into the
        # reader's form along with every other link in the block.
        link["href"] = "##{PREFIX}#{slug}"

        if @anchors.linkable?
          decorate(link)
        else
          # A heading this pull request deleted. A link to it would be a link
          # into a struck-through strip, and nobody shares that.
          link.remove
        end
      end

      # comrak's numbering: the first `setup` is `setup`, the next `setup-1`,
      # and a later heading that is literally "Setup 1" becomes `setup-1-1`
      # rather than taking a slug already used.
      def unique(slug)
        candidate = slug
        suffix = 0
        while @seen.include?(candidate)
          suffix += 1
          candidate = "#{slug}-#{suffix}"
        end
        @seen << candidate
        candidate
      end

      def decorate(link)
        link["class"] = "anchor md-heading-link"
        link["data-testid"] = "heading-link"
        link.inner_html = ICON
      end

      # `user-content-x` → `user-content-<scope>-x`.
      def scoped(id)
        return id if @anchors.scope.nil? || !id.start_with?(PREFIX)

        "#{PREFIX}#{@anchors.scope}-#{id.delete_prefix(PREFIX)}"
      end

      # Markdown::Sanitizer has already rewritten every same-document link to
      # `#user-content-…`, so that prefix is exactly the set of links to fix.
      def same_document_link(link)
        href = link["href"].to_s
        return unless href.start_with?("##{PREFIX}")

        name = href.delete_prefix("##{PREFIX}")
        link["href"] =
          if @anchors.path
            "##{Anchors.fragment(@anchors.path, decode(name))}"
          else
            "##{scoped("#{PREFIX}#{name}")}"
          end
        link["data-turbo"] = "false"
      end

      # comrak percent-encodes a link destination (`[x](#über)` arrives as
      # `#%C3%BCber`) but not the id it points at, and the browser compares
      # the two decoded. Decoding here keeps {.fragment} from encoding the
      # `%` a second time; bytes that are not UTF-8 stay as they were written.
      def decode(name)
        decoded = name.b.gsub(/%\h\h/n) { |escape| escape[1..].hex.chr }.force_encoding(Encoding::UTF_8)
        decoded.valid_encoding? ? decoded : name
      end
    end
  end
end
