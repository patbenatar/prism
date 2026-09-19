# frozen_string_literal: true

module Markdown
  # Syntax highlighting for fenced code blocks.
  #
  # commonmarker bundles a syntect highlighter, but it inlines colours from a
  # fixed theme, which defeats dark mode and bloats every block. We disable it
  # and run Rouge over the `<pre lang="…">` elements instead (commonmarker emits
  # the language there because of `github_pre_lang: true`).
  #
  # Highlighting only rewrites the contents of `<code>`, so the `data-sourcepos`
  # attribute on the surrounding `<pre>` survives untouched.
  module Highlighter
    # Languages whose blocks are upgraded client-side instead. Highlighting them
    # would fight the Stimulus controllers that swap in a diagram or formula.
    SKIP = %w[mermaid math].freeze

    class << self
      def call(html)
        return html if html.blank? || !html.include?("<pre")

        fragment = Nokogiri::HTML5.fragment(html)
        changed = false

        fragment.css("pre[lang]").each do |pre|
          code = pre.at_css("code")
          next if code.nil?

          lexer = lexer_for(pre["lang"])
          next if lexer.nil?

          code.inner_html = formatter.format(lexer.lex(code.text))
          pre["class"] = [ pre["class"], "highlight" ].compact.join(" ")
          changed = true
        end

        changed ? fragment.to_html : html
      end

      private

      # Rouge does not know every info string GitHub does; an unknown language
      # simply renders unhighlighted rather than raising.
      def lexer_for(lang)
        lang = lang.to_s.strip.downcase
        return nil if lang.empty? || SKIP.include?(lang)

        Rouge::Lexer.find_fancy(lang)
      end

      # `HTML` (token classes) rather than `HTMLInline` (inline styles), so the
      # Tailwind dark variant can restyle code without re-rendering it.
      def formatter
        @formatter ||= Rouge::Formatters::HTML.new
      end
    end
  end
end
