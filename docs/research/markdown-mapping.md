# Markdown source mapping for rendered PR review

Research for the Rails 8.1 app that renders changed `.md` files in a GitHub PR and lets
reviewers comment on rendered blocks, anchored to source lines.

Everything marked **[verified]** was run locally against the real gem on
`aarch64-linux` / Ruby 3.2.3 (the container targets 3.4.9; the gem supports `>= 3.2, < 5`).
Test scripts live beside this file in the scratchpad (`proto.rb`, `test1.rb` … `perf2.rb`,
`fixture.md`).

---

## Decisions & recommendations

| Decision | Choice | Why |
|---|---|---|
| Renderer | **commonmarker 2.10.0** (comrak) | Only Ruby lib with reliable **end** lines, not just start lines |
| Rendering strategy | **AST walk + per-node `to_html`**, not whole-document HTML | AST exposes `html_block` positions the HTML renderer silently omits |
| Sanitizer | **rails-html-sanitizer 1.7.1**, `Rails::HTML5::SafeListSanitizer`, custom safelist | Defaults strip tables, task lists and `data-sourcepos` |
| Raw HTML | `unsafe: true` + `tagfilter: true` + sanitize every block | Defense in depth; comrak's own escaping is not a security boundary |
| Line breaks | `hardbreaks: false` | GitHub uses soft breaks in `.md` files, hard breaks only in comments |
| Anchor rule | Contiguous diff run in block → multi-line comment; otherwise first added line | Matches what GitHub's UI shows |
| Syntax highlighting | **Rouge 5.1.0**, post-process `<pre lang="x">` | comrak's built-in syntect highlighter inlines styles and is theme-locked |
| Mention autocomplete | Hand-rolled Stimulus controller | `@github/text-expander-element` is fine but not worth the importmap surface |
| Pending-review writes | **GraphQL `addPullRequestReviewThread`**, not REST | REST cannot add a comment to an existing pending review at all (§4.4) |

### Gem list

```ruby
gem "commonmarker", "~> 2.10"          # 2.10.0, 2026-08-24
gem "rails-html-sanitizer", "~> 1.7"   # 1.7.1 (pulls loofah 2.25.2, nokogiri 1.19.4)
gem "rouge", "~> 5.1"                  # 5.1.0
```

### Mapping rules (summary)

1. A block is **commentable** iff at least one of its source lines appears on the RIGHT side
   of the diff (added *or* context) **and inside a hunk**. Confirmed by the API researcher:
   `side` is documented as "Use RIGHT for additions that appear in green or unchanged lines
   that appear in white and are shown for context." Lines outside every hunk are rejected with
   422, "Pull request review thread line must be part of the diff", even though GitHub's own
   web UI allows commenting on expanded context. **Do not loosen this predicate.**
2. A block is **changed** iff at least one of its lines is an ADDED line.
3. **Anchor**: take the block's lines that are in the RIGHT diff set. If that set is
   contiguous and longer than one line, emit a multi-line comment `start_line..line`.
   Otherwise emit a single-line comment on the first added line, falling back to the first
   in-diff line.
4. Existing RIGHT-side comments attach to the block whose range contains `line`.
5. LEFT-side and outdated comments go to separate buckets (see §3.4).

---

## 0. Changes made during implementation (Workstream B)

Three rules in this report changed once the code met real input. The report
below is otherwise as researched; these supersede it.

1. **Child blocks are cut out of the parent's rendered HTML, not rendered from
   the AST.** Calling `to_html` on a `table_row` node **panics the Rust
   extension** ("rendered a table cell without a containing table"), which
   aborts the process rather than raising a Ruby exception. Rendering a list
   item standalone also renders it *loose* even when its parent list is tight,
   so the child markup would not match the page. Both problems disappear when
   children are selected out of the parent's own sanitized HTML by their
   `data-sourcepos` attribute. Child fragments are therefore **not
   re-sanitized**: a bare `<tr>` or `<li>` outside its table or list is an
   orphan that HTML5 fragment parsing discards.

2. **The html_region balance check counts tag depth; it does not compare a
   parser round-trip.** The round-trip heuristic sketched in §1.7 flags any
   markup an HTML parser merely *normalizes* — unquoted attributes, uppercase
   tags, a self-closing `<img />`, a boolean `checked` — and READMEs are full of
   exactly that. Each such block wrongly swallowed the blocks after it into one
   uncommentable region. `Markdown::Renderer#depth` now scans tags, skips void
   elements, comments and declarations, and reports the net nesting level. Six
   regression cases are pinned in the renderer test.

3. **Constants cannot live inside a `Data.define` block.** A constant assigned
   there lands in the enclosing module, not on the class, so `Anchor::SIDES` and
   `NotCommentable::REASONS` are assigned after the definition.

Unchanged and confirmed against the real gem in the container: the renderer
option set, the list-item `end_column == 0` clamp, per-node absolute sourcepos,
the sanitizer safelist, the diff line-set rules, and the anchor rule.

**Cost.** A 780-line document producing 600 blocks (including children) renders
in about 100 ms, roughly twice the estimate in §1.6 because child extraction
adds a Nokogiri parse per parent.

---

## 1. Renderer with source positions

### 1.1 Why commonmarker

| Library | Positions | Verdict |
|---|---|---|
| **commonmarker 2.10** (comrak, Rust) | start **and** end line/col, blocks + inlines + table cells | **Recommended** |
| kramdown + kramdown-parser-gfm | `element.options[:location]` = **start line only** | Rejected: no end line, so no block ranges |
| redcarpet | none | Rejected |
| markly (cmark-gfm fork of the old commonmarker) | AST access; sourcepos not documented | Rejected: unverifiable, and cmark-gfm sourcepos is block-start oriented |

kramdown's `:location` is a single integer assigned at parse time
([GFM parser rdoc](https://kramdown.gettalong.org/rdoc/Kramdown/Parser/GFM.html)). Deriving
an end line means walking to the next sibling and subtracting, which breaks on nested
structures. Not worth it.

markly wraps cmark-gfm and explicitly exists because "the Rust implementation did not provide
[AST] functionality" ([markly readme](https://github.com/ioquatix/markly)). Its readme does not
document sourcepos at all. commonmarker 2.x *does* expose the AST (`Commonmarker.parse`,
`node.source_position`), so markly's reason to exist does not apply to us.

### 1.2 Platform / Docker **[verified]**

commonmarker 2.10.0 ships precompiled native gems for **9 platforms including
`aarch64-linux` and `aarch64-linux-musl`** (confirmed via the RubyGems API, not the web page,
which truncates the list). Installed on the aarch64 host in seconds with **no Rust toolchain
invoked**:

```
Successfully installed commonmarker-2.10.0-aarch64-linux
```

So `ruby:3.4.9-slim` on aarch64 needs no `cargo` in the Dockerfile. Add to be safe:

```ruby
# Gemfile.lock must carry the platform, else Docker falls back to a source build
# bundle lock --add-platform aarch64-linux x86_64-linux
```

Precompiled gems declare `ruby_version >= 3.2, < 4.1.dev`, so Ruby 3.4.9 is covered.

### 1.3 Option set **[verified]**

```ruby
EXTENSION = {
  table: true, tasklist: true, strikethrough: true, autolink: true,
  tagfilter: true,                    # GFM raw-HTML filter (script/iframe/etc.)
  footnotes: true,
  header_ids: "user-content-",        # same prefix GitHub uses
  front_matter_delimiter: "---",      # YAML front matter becomes its own node
  alerts: true,                       # > [!NOTE] blocks
  math_dollars: true, math_code: true,
}.freeze

RENDER = {
  sourcepos: true,
  unsafe: true,                       # emit raw HTML; we sanitize afterwards
  hardbreaks: false,                  # .md files use soft breaks (see §2.1)
  github_pre_lang: true,              # <pre lang="ruby"> like GitHub
  escaped_char_spans: false,
  tasklist_classes: true,
}.freeze
```

### 1.4 What actually gets `data-sourcepos` **[verified]**

Contrary to the common claim that sourcepos is block-only, comrak emits it on **inlines and
table cells too**:

```html
<table data-sourcepos="16:1-19:17">
<tr data-sourcepos="16:1-16:17">
<th data-sourcepos="16:2-16:8">Col A</th>
...
<p data-sourcepos="49:1-49:99">Final paragraph with
  <code data-sourcepos="49:22-49:27">code</code>,
  <strong data-sourcepos="49:30-49:37">bold</strong>,
  <a data-sourcepos="49:52-49:70" href="https://example.com">https://example.com</a>.</p>
```

`<tr>` and `<td>`/`<th>` **do** carry sourcepos, so per-table-row commenting is feasible.

Nested lists work correctly:

```html
<ul data-sourcepos="21:1-25:12">
<li data-sourcepos="21:1-21:10">item one</li>
<li data-sourcepos="22:1-24:12">item two
<ul data-sourcepos="23:3-24:12">
<li data-sourcepos="23:3-23:12">nested a</li>
```

### 1.5 The two real gotchas **[verified]**

**(a) List-item end-line bleed.** comrak's own docs say sourcepos is reliable "for core block
items (excluding lists and list items)"
([docs.rs Render](https://docs.rs/comrak/latest/comrak/options/struct.Render.html)). Observed:
the last item of a tight list followed by a blank line reports an end position on the *next*
line with **column 0**:

```html
<li data-sourcepos="25:1-26:0">item three</li>   <!-- content is only on line 25 -->
<li data-sourcepos="28:1-29:0">ordered two</li>
```

The `end_column == 0` marker makes this trivially detectable. Clamp it:

```ruby
def clamp(sp)
  e = sp[:end_line]
  e -= 1 if sp[:end_column].to_i.zero? && e > sp[:start_line]
  [sp[:start_line], [e, sp[:start_line]].max]
end
```

The same bleed appears on indented code blocks (`1:2-3:0` for two lines of content). The
top-level `<ul>`/`<ol>` ranges are correct; only the trailing `<li>` bleeds.

**(b) Raw HTML blocks get no sourcepos in the HTML renderer, but do in the AST.** This is the
single strongest argument for the AST approach:

```
HTML renderer:  <details>            <-- no data-sourcepos at all
AST:            html_block {start_line: 51, end_line: 52}
                html_block {start_line: 56, end_line: 56}
```

Note also that `<details>…</details>` with markdown inside is parsed as **two separate
`html_block` nodes with a paragraph between them**. Rendering and sanitizing them
independently destroys the nesting: Loofah drops the orphan `</details>` to the empty string
and auto-closes the opener. Handled by the coalescing pass in §1.7.

**Other position behaviours, all verified:**

| Construct | Behaviour |
|---|---|
| Fenced code block | Range **includes the closing fence line** (`33:1-37:3`) |
| Setext heading | Range **includes the underline** (`11:1-12:14`) |
| Front matter | Own `frontmatter` node, `1..4`; following lines keep absolute numbers |
| CRLF | Line numbers correct, no shift |
| No trailing newline | No effect on line numbers |
| BOM | Line numbers correct; only `start_column` shifts (1 → 4). Strip it anyway |
| Tables | Range spans header through last row; the `---|---` delimiter row is inside the range but produces no `<tr>` |
| Loose lists | Each `<li>` wraps its content in `<p>`; no bleed on the last item |
| Multi-paragraph list item | Item range spans all its paragraphs (`1:1-3:21`) |

### 1.6 Recommended approach: AST walk, per-node render

Relying on the built-in HTML renderer would mean parsing the output string with Nokogiri and
wrapping top-level elements. That fails for exactly the raw-HTML case above, and it makes
block identity depend on DOM shape. Walking the AST gives all three things the task asks for:
a stable id, a reliable `[start_line, end_line]`, and a natural seam to inject gutter markup.

Per-node `to_html` re-emits **absolute** sourcepos values (verified), so nodes stay
self-describing after extraction.

**Performance is a non-issue [verified].** On a 2480-line document producing 758 blocks:

| Stage | Time per render |
|---|---|
| Parse + per-node render | 20 ms |
| Sanitize (per block) | 130 ms |
| Sanitize (whole doc, for comparison) | 130 ms |
| **Total pipeline** | **~160 ms** |

Per-block sanitizing costs the same as one whole-document pass, so there is no reason to
avoid it.

### 1.7 The renderer

```ruby
# app/services/markdown/renderer.rb
require "digest"

module Markdown
  class Renderer
    EXTENSION = { table: true, tasklist: true, strikethrough: true, autolink: true,
                  tagfilter: true, footnotes: true, header_ids: "user-content-",
                  front_matter_delimiter: "---", alerts: true,
                  math_dollars: true, math_code: true }.freeze

    RENDER = { sourcepos: true, unsafe: true, hardbreaks: false, github_pre_lang: true,
               escaped_char_spans: false, tasklist_classes: true }.freeze

    Block = Struct.new(:id, :type, :start_line, :end_line, :html,
                       :commentable, :changed, :anchor_line, :anchor_start_line,
                       keyword_init: true) do
      def range = (start_line..end_line)
      def lines = range.to_a
    end

    def call(markdown)
      src   = normalize(markdown)
      doc   = Commonmarker.parse(src, options: { extension: EXTENSION })
      nodes = doc.each.to_a.reject { |n| n.type == :frontmatter }

      coalesce_html_regions(nodes).map.with_index do |(type, first, last, html), i|
        Block.new(id: block_id(i, first, last, html), type: type,
                  start_line: first, end_line: last, html: Sanitizer.call(html))
      end
    end

    private

    # BOM and CRLF do not shift line numbers, but normalizing keeps columns honest
    # and keeps our own line-slicing of the raw source consistent with comrak's.
    def normalize(md) = md.delete_prefix("﻿").gsub("\r\n", "\n")

    def clamp(sp)
      e = sp[:end_line]
      e -= 1 if sp[:end_column].to_i.zero? && e > sp[:start_line]  # see 1.5(a)
      [sp[:start_line], [e, sp[:start_line]].max]
    end

    def render_node(node)
      node.to_html(options: { extension: EXTENSION, render: RENDER },
                   plugins: { syntax_highlighter: nil })
    end

    # An html_block that HTML5-parses to something different from its own source is an
    # unclosed fragment (e.g. a bare "<details>"). Absorb following nodes until balanced.
    def unbalanced?(html)
      Nokogiri::HTML5.fragment(html).to_html.gsub(/\s+/, "") != html.gsub(/\s+/, "")
    end

    def coalesce_html_regions(nodes)
      out = []
      pending = nil
      nodes.each do |n|
        first, last = clamp(n.source_position)
        html = render_node(n)
        if pending
          pending[:last] = last
          pending[:html] << html
          unless unbalanced?(pending[:html])
            out << [:html_region, pending[:first], pending[:last], pending[:html]]
            pending = nil
          end
        elsif n.type == :html_block && unbalanced?(html)
          pending = { first: first, last: last, html: html.dup }
        else
          out << [n.type, first, last, html]
        end
      end
      out << [:html_region, pending[:first], pending[:last], pending[:html]] if pending
      out
    end

    # Stable across re-renders of identical content; changes when the block moves or
    # its content changes, which is what we want for Turbo Frame ids.
    def block_id(index, first, last, html)
      "b#{index}-#{first}-#{last}-#{Digest::SHA256.hexdigest(html)[0, 8]}"
    end
  end
end
```

Verified output on a `<details>` document:

```
paragraph    1..1   <p data-sourcepos="1:1-1:11">para before</p>
html_region  3..8   <details> <summary>Click</summary> <p …>inner <em>markdown</em></p> </details>
paragraph   10..10  <p data-sourcepos="10:1-10:10">para after</p>
```

---

## 2. GitHub-fidelity rendering

### 2.1 Line breaks

GitHub renders **soft breaks as soft breaks in `.md` files**, and as `<br>` only in issues,
comments and PR descriptions
([community discussion 10981](https://github.com/orgs/community/discussions/10981),
[github/markup#1050](https://github.com/github/markup/issues/1050)).
commonmarker defaults `hardbreaks: true`, which is wrong for us. **Set it to `false`.**

### 2.2 Feature coverage

| Feature | comrak | GitHub | Action |
|---|---|---|---|
| Tables, task lists, strikethrough, autolinks | yes | yes | extensions on |
| Footnotes | yes | yes | on; note the `<section class="footnotes">` is emitted per definition |
| Heading anchors | `header_ids` | yes | use prefix `user-content-` |
| Alerts `> [!NOTE]` | yes | yes | emits `<div class="markdown-alert markdown-alert-note">` |
| Math `$…$`, `$$…$$`, ` ```math ` | yes | yes | emits `data-math-style="inline"/"display"` |
| Mermaid | no (plain code block) | yes | client-side, see below |
| GeoJSON / TopoJSON / ASCII STL | no | yes | out of scope for v1 |

GitHub confirms mermaid, GeoJSON, TopoJSON and STL render "in GitHub Issues, GitHub
Discussions, pull requests, wikis, and Markdown files"
([creating diagrams](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/creating-diagrams)),
and math via MathJax in the same contexts
([writing mathematical expressions](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/writing-mathematical-expressions)).

**Verified comrak output** for the special blocks:

```html
<pre lang="mermaid" data-sourcepos="63:1-66:3"><code>graph TD;
 A--&gt;B;
</code></pre>

<span data-math-style="inline" data-sourcepos="1:8-1:12">x^2</span>
<pre lang="math" data-math-style="display" data-sourcepos="7:1-9:3"><code>z=1</code></pre>
```

Both are easy to upgrade in a Stimulus controller: find `pre[lang=mermaid]` and hand the text
to mermaid's ESM build; find `[data-math-style]` and hand it to KaTeX. Keep the `<pre>` in the
DOM as the fallback so the block stays commentable even if the JS never loads.

**A caveat worth flagging.** GitHub's rich diff is not a straight render of the head file: it
is a *diff* of two renders, and its handling of mermaid inside that view is not documented.
Chasing byte-fidelity with it is a losing game. Aim for "reads the same", not "renders
identically".

This also confirms the product premise. GitHub explicitly does **not** let you comment on the
rendered view; reviewers "have to mentally map rendered content back to raw diff lines to
comment"
([community discussion 186730](https://github.com/orgs/community/discussions/186730)).
That is exactly the gap this app fills.

### 2.3 Syntax highlighting

commonmarker bundles a syntect highlighter, enabled by default, that inlines colours from a
`.tmtheme`. That is the wrong shape for us: it hardcodes one theme, defeats dark mode, and
bloats every block. **Disable it** (`plugins: { syntax_highlighter: nil }`) and run Rouge over
the emitted `<pre lang="…">` instead. With `github_pre_lang: true` the language is already on
the element, and highlighting only touches the `<code>` text, so `data-sourcepos` survives.

```ruby
# app/services/markdown/highlighter.rb
module Markdown
  module Highlighter
    FORMATTER = Rouge::Formatters::HTMLInline  # or HTML + a CSS theme for dark mode
    SKIP = %w[mermaid math].freeze

    def self.call(html)
      frag = Nokogiri::HTML5.fragment(html)
      frag.css("pre[lang]").each do |pre|
        lang = pre["lang"].to_s.downcase
        next if lang.empty? || SKIP.include?(lang)
        lexer = Rouge::Lexer.find_fancy(lang) or next
        code  = pre.at_css("code") or next
        code.inner_html = Rouge::Formatters::HTML.new.format(lexer.lex(code.text))
        pre["class"] = "highlight"
      end
      frag.to_html
    end
  end
end
```

Prefer `Rouge::Formatters::HTML` plus a stylesheet over `HTMLInline`, so the Tailwind dark
variant can restyle it. Run the highlighter **before** sanitizing, and allow `span` + `class`
in the safelist (both already are).

### 2.4 Sanitization

We render untrusted repository content, so `unsafe: true` must be paired with a real
sanitizer. Two independent layers:

1. **`tagfilter: true`** — GFM's own filter. Verified: `<script>alert(1)</script>` comes out
   as `&lt;script&gt;alert(1)&lt;/script&gt;`. Useful, but it is a blocklist, so it is not the
   boundary.
2. **`Rails::HTML5::SafeListSanitizer`** — Loofah/Nokogiri HTML5, the actual boundary.

**The defaults are unusable for us [verified].** Running the default safelist over rendered
markdown strips `data-sourcepos`, `id`, `details`, `summary`, `input` and the entire table:

```
input:  <p data-sourcepos="1:1-1:5" id="x" class="y">hi</p>
        <details><summary>s</summary>body</details>
        <table><tr><td align="right">c</td></tr></table>
output: <p class="y">hi</p>
        sbody
        c
```

The custom safelist below keeps GitHub-like HTML and our own attributes, and **still strips
the dangerous parts** (verified: `onerror` removed, `javascript:` href removed while the
`<a>` is kept, `<script>` neutralized):

```ruby
# app/services/markdown/sanitizer.rb
module Markdown
  module Sanitizer
    TAGS = %w[
      h1 h2 h3 h4 h5 h6 p br hr blockquote pre code span div
      ul ol li dl dt dd table thead tbody tfoot tr th td caption
      a img picture source figure figcaption
      strong b em i del ins s sup sub kbd samp var abbr mark small q cite
      details summary section article aside input
    ].freeze

    ATTRIBUTES = %w[
      href src alt title id class align width height loading decoding
      type checked disabled start reversed value colspan rowspan scope
      lang dir role rel srcset sizes open cite
      data-sourcepos data-math-style data-footnotes data-footnote-ref
      data-footnote-backref data-footnote-backref-idx data-heading-content
      aria-label aria-hidden
    ].freeze

    SANITIZER = Rails::HTML5::SafeListSanitizer.new

    def self.call(html)
      SANITIZER.sanitize(html, tags: TAGS, attributes: ATTRIBUTES).to_s
    end
  end
end
```

Notes on the safelist:

- `input` is needed for task-list checkboxes; it is safe because `type`, `checked` and
  `disabled` are the only relevant attributes allowed and no `name`/`form` is.
- `target` is stripped by default. If you want `target="_blank"`, add it **with `rel`** and
  force `rel="noopener noreferrer"` in a post-pass.
- `style` is deliberately absent. Do not add it.
- Images from arbitrary repos will hit third-party URLs. Consider a
  `Content-Security-Policy` with `img-src https:` and, later, a camo-style proxy.

Sanitize the **block HTML only**, then wrap it in our own trusted markup. Our gutter and
`data-block-id` attributes are generated by us and never pass through the sanitizer, so they
cannot be stripped or spoofed.

---

## 3. The mapping model

### 3.1 Diff parsing

```ruby
# app/services/markdown/diff_map.rb
module Markdown
  # right_lines / left_lines: line_number => :added | :removed | :context
  # right_of_left: base line number => the head line number it maps to (for LEFT comments)
  DiffMap = Struct.new(:right_lines, :left_lines, :added, :removed, :right_of_left,
                       keyword_init: true) do
    def commentable_right?(line) = right_lines.key?(line)
    def added?(line)             = right_lines[line] == :added

    HUNK = /\A@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/

    def self.parse(patch)
      map = new(right_lines: {}, left_lines: {}, added: [], removed: [], right_of_left: {})
      return map if patch.nil?

      base = head = nil
      patch.each_line do |raw|
        line = raw.chomp
        if (m = line.match(HUNK))
          base, head = m[1].to_i, m[2].to_i
          next
        end
        next if base.nil?

        case line[0]
        when "+"
          map.right_lines[head] = :added
          map.added << head
          head += 1
        when "-"
          map.left_lines[base] = :removed
          map.removed << base
          map.right_of_left[base] = head   # head line this deletion sits in front of
          base += 1
        when "\\"                          # "\ No newline at end of file"
          next
        else                               # " " context, and empty-string context lines
          map.right_lines[head] = :context
          map.left_lines[base]  = :context
          map.right_of_left[base] = head
          base += 1
          head += 1
        end
      end
      map
    end
  end
end
```

Two details that bite in practice: GitHub's `patch` strings contain **zero-width context
lines** (a context line that is empty in the file arrives as a single space, but some clients
strip trailing whitespace, leaving `""`). The `else` branch treats both as context. And
`\ No newline at end of file` must be skipped without advancing either counter.

### 3.2 Annotating blocks

```ruby
# app/services/markdown/annotator.rb
module Markdown
  module Annotator
    def self.call(blocks, diff_map)
      blocks.each do |block|
        lines   = block.lines
        in_diff = lines.select { |l| diff_map.commentable_right?(l) }

        block.commentable = in_diff.any?
        block.changed     = lines.any? { |l| diff_map.added?(l) }
        next unless block.commentable

        if contiguous?(in_diff) && in_diff.size > 1
          # Whole run is commentable: use a GitHub multi-line comment.
          block.anchor_start_line = in_diff.first
          block.anchor_line       = in_diff.last
        else
          # Single line, or a block split across hunks: one deterministic anchor.
          block.anchor_start_line = nil
          block.anchor_line = lines.find { |l| diff_map.added?(l) } || in_diff.first
        end
      end
      blocks
    end

    def self.contiguous?(lines) = lines.each_cons(2).all? { |a, b| b == a + 1 }
  end
end
```

**Verified behaviour:**

```
heading     1..1   commentable=true  changed=false anchor=1
paragraph   3..3   commentable=true  changed=false anchor=3
heading     5..5   commentable=true  changed=true  anchor=5
paragraph   7..8   commentable=true  changed=true  anchor=7..8
table      10..12  commentable=true  changed=true  anchor=10..12
list       14..15  commentable=true  changed=false anchor=14..15

# block spans 10..18, only 12..14 in the diff:
paragraph  10..18  commentable=true  changed=true  anchor=12..14

# block spans 10..18, lines 10 and 14 in the diff but not 11..13:
paragraph  10..18  anchor=10
```

**Why multi-line over single-line.** The task asks which to prefer. Use multi-line when the
in-diff run is contiguous. GitHub's UI then highlights the whole range, which is exactly what
the reviewer selected by clicking the block, so the comment reads correctly when someone
opens it in GitHub's own Files-changed view. Both `start_line` and `line` are drawn from the
in-diff set, so the "both endpoints must be in the diff" constraint holds by construction.
Fall back to a single line when the run is not contiguous, because GitHub cannot express a
gapped range and a spanning comment would claim lines that are not in the diff.

**Do not encode "both endpoints on the same side" as an invariant.** Per the API researcher,
`side` and `start_side` are documented independently: `side` describes "whether the last line
of the comment range is a deletion or addition", `start_side` is "the starting side of the
diff". Nothing requires them to match, and a LEFT-to-RIGHT range appears to be expressible.
It is moot for the RIGHT-only ranges this design emits, but a validation rule asserting
sameness would be wrong in general, and would block a future base-side commenting feature.
Ordering `start_line` before `line` **is** required, though undocumented.

Whether every line *between* the endpoints must also be in the diff is undocumented. The
contiguous-run rule satisfies the strictest reading, so it needs no change either way.

### 3.3 Placing existing comments

```ruby
# app/services/markdown/comment_placement.rb
module Markdown
  module CommentPlacement
    Result = Struct.new(:by_block_id, :removed_side, :outdated, keyword_init: true)

    def self.call(comments, blocks, diff_map)
      result = Result.new(by_block_id: Hash.new { |h, k| h[k] = [] },
                          removed_side: [], outdated: [])

      comments.each do |c|
        if c.line.nil?                                  # position == nil => outdated
          result.outdated << c
        elsif c.side == "RIGHT"
          block = blocks.find { |b| b.range.cover?(c.line) }
          block ? result.by_block_id[block.id] << c : result.outdated << c
        else                                            # LEFT: comment on a deleted line
          head = diff_map.right_of_left[c.line]
          block = head && blocks.find { |b| b.range.cover?(head) }
          block ? result.by_block_id[block.id] << c : result.removed_side << c
        end
      end
      result
    end
  end
end
```

Three buckets, each with its own affordance:

- **RIGHT-side** — the normal case. Thread renders under the block containing `line`.
- **LEFT-side** — the comment is on a line that no longer exists. `right_of_left` maps the
  base line to the head line that replaced it, so the thread lands on the block that now
  occupies that spot, rendered in a muted "on removed content" style with the original text
  quoted. If the deletion fell outside any block, it goes to the removed bucket.
- **Outdated** — GitHub nulls `line` when the diff moved past the comment; `original_line`
  still points into `original_commit_id`. Do **not** guess a block. Render these in a
  collapsed "Outdated comments" section at the bottom, each showing `original_line` and
  `diff_hunk` for context. Guessing here produces confidently wrong placements, which is worse
  than a visible bucket. If we are on GraphQL anyway (§4.4), prefer the thread's `isOutdated`
  field over inferring outdatedness from a null `line`.

> **`right_of_left` is a display convention, never an anchor.** A deleted line has no head-side
> counterpart; the map only answers "which head line now sits where this deletion was", which
> is enough to *place* an existing thread in the rendered view. When **writing** a comment on
> removed content, send `side: "LEFT"` with the **base-side** line number. Passing the mapped
> head line would silently anchor the comment to unrelated content. Worth a type-level guard:
> keep the write-path anchor as a `(side, line)` pair constructed only from the side it belongs
> to.

### 3.4 Deleted content and the base side

**v1 recommendation: render HEAD only.** A split rendered view doubles the rendering work and
the interaction surface, and most markdown review is about what the file now says.

Mark up the head render with:

- a gutter marker on every `changed` block,
- `commentable=false` blocks visibly inert (no `+` button), and
- **removed blocks shown inline as collapsed chunks.**

Compute removed blocks with the *same* renderer over the base file content:

```ruby
base_blocks = renderer.call(base_source)
removed = base_blocks.select { |b| b.lines.all? { |l| diff_map.left_lines[l] == :removed } }
# Insert each before the head block covering right_of_left[b.start_line - 1] + 1,
# rendered collapsed, in a muted style, not commentable on the RIGHT side.
```

A block is "removed" only if **all** its base lines are deletions. A block with a mix of
deleted and context lines still exists on the head side in modified form, and its head
counterpart already carries the `changed` marker.

Fetching the base content costs one extra `contents` API call per file. Worth it.

**Blocks spanning hunks.** A paragraph whose lines fall in two hunks with untouched lines
between is one block with a non-contiguous in-diff set. It is commentable, it is marked
changed, and it anchors to a single line (§3.2). For highlighting, highlight the **whole
block**, not the individual lines: the rendered view has no line granularity, and a
half-highlighted paragraph reads as a rendering bug.

### 3.5 Front matter

`front_matter_delimiter: "---"` is verified working. Front matter becomes a `frontmatter`
node covering lines 1..4, and **every following block keeps its absolute line number** (the
first heading after a 5-line front matter block correctly reported line 6). Without the
option, `---\ntitle: x\n---` parses as a setext heading followed by a thematic break, which
both renders wrong and shifts nothing but looks alarming.

Render front matter as a collapsed metadata table rather than dropping it: it is frequently
the thing being changed in docs PRs. It is commentable like any other block.

### 3.6 Line-number stability

| Input quirk | Verified effect | Mitigation |
|---|---|---|
| CRLF | none on line numbers | `gsub("\r\n", "\n")` anyway |
| No trailing newline | none | none needed |
| BOM | `start_column` 1 → 4 on line 1 only | `delete_prefix("﻿")` |
| Tabs | `start_column` reflects byte offset | use lines only, never columns |
| Last `<li>` of a tight list | end line +1, `end_column == 0` | clamp (§1.5a) |
| Indented code block | same bleed | same clamp |
| Fenced code block | includes closing fence | intended; keep |
| Setext heading | includes underline | intended; keep |

**Use lines, never columns.** Columns are byte-based unless `sourcepos_chars: true`, and
GitHub review comments are line-anchored, so columns buy nothing.

### 3.7 Test suite to pin this behaviour

comrak's sourcepos has changed across releases (issue #301 was a real sourcepos bug, fixed in
PR #439). Pin the behaviour with golden fixtures so a `bundle update` cannot silently break
anchoring:

```ruby
# test/services/markdown/renderer_test.rb
class Markdown::RendererTest < ActiveSupport::TestCase
  # Each fixture is a .md file plus a .expected file of "type start..end" lines.
  Dir[Rails.root.join("test/fixtures/markdown/*.md")].each do |path|
    name = File.basename(path, ".md")
    test "block ranges for #{name}" do
      blocks = Markdown::Renderer.new.call(File.read(path))
      actual = blocks.map { |b| "#{b.type} #{b.start_line}..#{b.end_line}" }.join("\n")
      assert_equal File.read(path.sub(/\.md\z/, ".expected")).strip, actual.strip
    end
  end
end
```

Fixtures to ship on day one: tight list, loose list, nested list, multi-paragraph list item,
table, table with only a header, fenced code, indented code, setext heading, front matter,
alert, footnote, nested blockquote, `<details>` wrapping markdown, CRLF file, BOM file, file
with no trailing newline, and a file whose last line is a list item.

Add one invariant test that is stronger than any fixture:

```ruby
test "every block range is within the file and blocks never overlap" do
  blocks.each_cons(2) { |a, b| assert a.end_line < b.start_line, "#{a.inspect} overlaps #{b.inspect}" }
  assert blocks.last.end_line <= source.lines.size
end
```

That single assertion would have caught the `26:0` bleed.

---

## 4. Frontend interaction (Hotwire)

### 4.1 Block markup

The renderer's output is wrapped by a partial. Our attributes live on our wrapper, never on
sanitized content:

```erb
<%# app/views/markdown/_block.html.erb %>
<div class="md-block group relative <%= "md-block--changed" if block.changed %>"
     id="block_<%= block.id %>"
     data-controller="md-block"
     data-md-block-id-value="<%= block.id %>"
     data-md-block-start-line-value="<%= block.start_line %>"
     data-md-block-end-line-value="<%= block.end_line %>"
     data-md-block-anchor-line-value="<%= block.anchor_line %>"
     data-md-block-anchor-start-line-value="<%= block.anchor_start_line %>"
     data-md-block-commentable-value="<%= block.commentable %>">

  <% if block.commentable %>
    <button class="md-gutter opacity-0 group-hover:opacity-100 absolute -left-8 top-1"
            data-action="md-block#openForm" aria-label="Comment on this block">+</button>
  <% end %>

  <div class="md-content"><%= raw block.html %></div>

  <%= turbo_frame_tag "threads_#{block.id}" do %>
    <%= render partial: "markdown/thread", collection: threads_for(block), as: :thread %>
  <% end %>
  <%= turbo_frame_tag "form_#{block.id}" %>
</div>
```

`raw` is safe here only because `block.html` came out of the sanitizer. Make that a hard rule
and consider returning an `ActiveSupport::SafeBuffer` from `Sanitizer.call` so it cannot be
forgotten.

The gutter `+` on hover mirrors GitHub. Changed blocks get a left border via
`md-block--changed`; the whole block highlights, per §3.4.

### 4.2 Comment form

`md-block#openForm` loads the empty `form_<id>` Turbo Frame from a route carrying the path,
anchor line, optional start line and side. The server renders the form; submitting it posts to
GitHub and returns a Turbo Stream that appends the new thread to `threads_<id>` and clears the
form frame. Nothing is persisted locally, which is exactly what the frame boundary gives us.

### 4.3 Mention autocomplete

`@github/text-expander-element` is a clean dependency-free custom element with a good event
API (`text-expander-change` / `-value` / `-committed`), pinnable with
`bin/importmap pin @github/text-expander-element --download`. But it is another vendored asset
to keep current, and it only solves the menu mechanics.

**Recommendation: hand-roll a Stimulus controller.** The behaviour is small: on `input`, match
`/(?:^|\s)@(\w{0,30})$/` against the caret position, fetch collaborators once per PR and cache
in the controller, filter client-side, render a listbox, and splice the chosen login into the
textarea. That is roughly 80 lines and avoids an importmap pin, and it leaves the markup under
our control for accessibility. Revisit the library if requirements grow to multiple trigger
keys.

Emoji shortcodes: skip the client side. commonmarker's `shortcodes` extension is on by default
and expands `:tada:` at render time, which covers reading. For authoring, a `:` trigger in the
same controller is a cheap follow-on if anyone asks.

### 4.4 Pending review UX

Since we persist nothing, **the pending review must live on GitHub**, which it happily does.
GitHub's review objects have a `PENDING` state that is invisible to everyone but the author
until submitted. The UX contract:

1. First comment on the PR creates a review in pending state and adds the comment to it.
2. Subsequent comments are added to that existing pending review.
3. The header shows a live count of pending comments, read back from GitHub on each page load.
4. Submitting sends the event: `APPROVE`, `REQUEST_CHANGES` or `COMMENT`.

A page refresh survives because the pending review is server-side state on GitHub: on load,
look for the current viewer's existing pending review and rehydrate the count and the
per-block threads from its comments. Two browser tabs stay consistent for free.

**Step 2 must go through GraphQL.** The API researcher confirmed that one pending review per
user per PR is a hard limit (a second create returns 422), and — the part that changes our
design — **REST has no endpoint that adds a comment to an existing pending review**
(community discussion 168380 is the open request for one). The REST-only workarounds are both
bad: delete and recreate the entire review on every comment, or batch every comment into a
single create call, which defeats the incremental UX and loses work on a crash.

The supported path is `addPullRequestReviewThread`, which takes `pullRequestReviewId` to
attach a draft thread to the existing pending review. Pass `pullRequestId` alone to post
immediately, or `pullRequestReviewId` alone to add to the draft, never both. Replies into a
pending review use `addPullRequestReviewThreadReply`.

Practical consequence for this component: the block anchor we compute must serialize to the
GraphQL input shape (`path`, `line`, `startLine`, `side`, `startSide`), not just the REST one.
They carry the same information with different casing, so keep the anchor as a plain value
object and let the GitHub client do the naming.

Rehydration reads `state == PENDING` off the thread comments in the same `reviewThreads` query
that feeds §3.3, so it costs no extra round trip. The REST fallback is listing reviews and
finding the one with no `submitted_at`.

---

## 5. What I could not verify, and what needs a spike

1. **Mermaid in the PR rich diff specifically.** GitHub documents mermaid rendering in
   "Markdown files" and "pull requests", but I could not confirm whether the rich-diff view of
   a changed `.md` runs mermaid, or only the file view does. Low risk: we render it ourselves
   either way.

2. **`html_region` coalescing under adversarial input.** The `unbalanced?` probe compares a
   whitespace-stripped HTML5 fragment round-trip against its input. It works on the cases I
   tested, but it is a heuristic, and a pathological document could make it absorb the rest of
   the file into one block. **Spike this**: add a cap (absorb at most N nodes or M lines, then
   flush), and fuzz it against a corpus of real READMEs. This is the weakest part of the
   design.

3. **comrak sourcepos on description lists** is called out as buggy in comrak's own docs. We
   do not enable `description_lists`, so this is moot unless someone turns it on.

4. ~~GitHub's exact "commentable line" rule.~~ **Resolved** by the API researcher: added and
   context lines within hunks, exactly as `DiffMap#commentable_right?` implements it. The
   residual item is a **product** problem, not a technical one. GitHub's web UI lets you
   comment on expanded context lines; the REST and GraphQL APIs both refuse with 422. So a
   block that sits entirely outside every hunk will be inert in our UI while appearing
   commentable on github.com. Decide deliberately how to present that: a disabled gutter with
   a tooltip is honest, silently omitting the button is confusing. This is the single largest
   constraint on the product.

5. **Multi-line endpoint rules are doc-derived, not tested.** That both endpoints must be in
   the diff, that `start_line` must precede `line`, and that mixed LEFT/RIGHT ranges are
   accepted are all read off parameter descriptions rather than observed. A five-minute probe
   against a scratch PR would settle all three. I did not run it, since posting to a real
   repository is an outward-facing action outside this research task. Worth doing before
   relying on the multi-line path.

6. **GraphQL dependency for pending reviews.** Incremental pending-review comments are not
   expressible in REST at all (§4.4). If the app was planned as REST-only, that assumption is
   now broken and the GitHub client needs a GraphQL path.

7. **Ruby 3.4.9 on aarch64** — I verified the precompiled gem on Ruby 3.2.3, aarch64-linux.
   The 3.4 build is the same platform gem and the version constraint covers it, but run
   `bundle install` in the real container once before trusting it.

8. **Rouge language coverage versus GitHub's linguist.** Rouge will not recognise every info
   string GitHub does. `Rouge::Lexer.find_fancy` returning nil is handled (block renders
   unhighlighted), so this degrades gracefully.

---

## Verified sources

- [commonmarker on RubyGems](https://rubygems.org/gems/commonmarker) and the
  [versions API](https://rubygems.org/api/v1/versions/commonmarker.json) (platform list)
- [commonmarker README](https://github.com/gjtorikian/commonmarker) (options, node API)
- [comrak Render options](https://docs.rs/comrak/latest/comrak/options/struct.Render.html)
  (the "excluding lists and list items" caveat)
- [comrak issue #301](https://github.com/kivikakk/comrak/issues/301) (historical sourcepos bug)
- [GitHub: creating diagrams](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/creating-diagrams)
- [GitHub: writing mathematical expressions](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/writing-mathematical-expressions)
- [community discussion 186730](https://github.com/orgs/community/discussions/186730) (cannot
  comment on rendered markdown)
- [community discussion 10981](https://github.com/orgs/community/discussions/10981) and
  [github/markup#1050](https://github.com/github/markup/issues/1050) (soft line breaks)
- [rails-html-sanitizer README](https://github.com/rails/rails-html-sanitizer)
- [html-pipeline SanitizationFilter](https://github.com/gjtorikian/html-pipeline/blob/main/lib/html_pipeline/sanitization_filter.rb)
- [kramdown GFM parser](https://kramdown.gettalong.org/rdoc/Kramdown/Parser/GFM.html)
- [markly](https://github.com/ioquatix/markly)
- [@github/text-expander-element](https://github.com/github/text-expander-element)
