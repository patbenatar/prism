# frozen_string_literal: true

# Markup for the rendered file view.
#
# The interesting part is `block_body`. A list or a table is one rendered block,
# but a reviewer wants to comment on one bullet or one row, so the renderer also
# produced a child block per `<li>` and `<tr>`. Those children can't be rendered
# on their own — a bare `<li>` outside its list is not valid HTML — so we weave
# their markers into the parent's HTML instead.
#
# That weaving happens **after** Markdown::Sanitizer has run, and it only ever
# adds our own generated attributes and elements through Nokogiri's DOM API,
# never by re-parsing a string of markup. Nothing from the repository is
# re-interpreted here, and nothing we add can be stripped or spoofed by it.
module PullRequestFilesHelper
  # Fallbacks for workstream E's partials. The file view renders E's composer,
  # thread card and pending tray; until those land the page still has to work,
  # so we check and fall back to a read-only rendering rather than raising.
  def review_partial?(name)
    lookup_context.exists?(name, [], true)
  end

  # --- ids -----------------------------------------------------------------

  # Every block id on the page is prefixed with its file's key.
  #
  # Markdown::Renderer numbers blocks from zero *per document*
  # ("b0-1-3-<sha8>"), which was unique while a page held one file and is not
  # now that it holds all of them: two files whose first block is the same
  # heading produce byte-identical ids, and with them duplicate `block_`,
  # `threads_` and `composer_` containers. The prefix travels with the id
  # everywhere — the gutter button's `data-block-id`, the composer's hidden
  # field, and so the Turbo Stream targets the write path builds from it.
  def block_dom_id(block, file_key) = "#{file_key}-#{block.id}"

  # The container a file's file-level threads render into, and the one
  # ReviewCommentsController streams a new file-level comment into.
  def file_threads_dom_id(path) = "file_threads_#{Review::Page.file_key(path)}"

  # --- the gutter ----------------------------------------------------------

  # The "+" beside a block. Emitted with plain data attributes rather than
  # Stimulus values so the markup does not depend on E's controller having
  # loaded — without JS it is an inert focusable button, with JS it opens the
  # composer.
  def gutter_button(annotated, path:, modifier: nil, testid: "gutter-add")
    content_tag(:button, "+", gutter_attributes(annotated, path: path, modifier: modifier,
                                                           testid: testid))
  end

  def gutter_attributes(annotated, path:, modifier: nil, testid: "gutter-add")
    file_key = Review::Page.file_key(path)

    block = annotated.block
    commentable = annotated.commentable?

    {
      "type" => "button",
      "class" => class_names("md-add", "md-add--muted" => !commentable, modifier => modifier.present?),
      "title" => commentable ? "Comment on this block" : uncommentable_explanation(annotated),
      "aria-label" => commentable ? "Comment on this block" : "Comment on this block (file-level)",
      "data-action" => "composer#open",
      "data-testid" => testid,
      "data-block-id" => block_dom_id(block, file_key),
      "data-block-text" => block.plain_text.to_s.truncate(300),
      "data-start-line" => block.start_line.to_s,
      "data-end-line" => block.end_line.to_s,
      "data-commentable" => commentable.to_s,
      "data-uncommentable-reason" => annotated.uncommentable_reason.to_s,
      "data-anchor" => annotated.anchor&.to_rest&.to_json,
      # Which file this block is in. Every other page fact the composer needs
      # sits on its own section's `data-composer-*`; the path is here too so a
      # handler holding only the button can still tell the files apart.
      "data-path" => path
    }.compact
  end

  # --- a file that isn't on the page --------------------------------------

  # Three different reasons a document is missing, three different sentences.
  # Prism explains its own limits rather than showing a blank space (DESIGN
  # §1), and the three are not interchangeable: one is about the file, one is
  # about GitHub, and one is about this page being full.
  def missing_content_title(page)
    case page.content_problem
    when :deferred then "Not rendered on this page"
    when :unavailable then "GitHub didn't send this file"
    else "Prism can't render this file"
    end
  end

  def missing_content_body(page)
    case page.content_problem
    when :deferred
      "This pull request has more Markdown than Prism renders in one request, " \
        "and the budget ran out above this file. It is still listed and still " \
        "reviewable on GitHub."
    when :unavailable
      "#{page.content_error_message} Every other file in this pull request is " \
        "still on the page; this one is a click away on GitHub."
    when :too_large
      "It's larger than Prism renders in a request. Reading it here would mean " \
        "parsing several megabytes of Markdown before the page could start, so " \
        "the file stays on GitHub."
    else
      "GitHub didn't return readable text for it at this commit — it may be " \
        "binary, or too large to serve. The file itself is still on GitHub."
    end
  end

  # The sentence Prism shows instead of disabling the affordance. DESIGN §7:
  # the difference must be visible before the click and stated in words after.
  def uncommentable_explanation(annotated)
    reason = annotated.uncommentable_reason
    return nil if reason.blank?

    Review::NotCommentable.new(reason: reason).explanation
  end

  # `added` / `modified` / `unchanged` → the block modifier that colors the
  # change bar and tints the body.
  def block_change_class(annotated)
    return nil unless annotated.changed?

    "md-block--#{annotated.change}"
  end

  # --- block bodies --------------------------------------------------------

  # A block's sanitized HTML with the per-child markers woven in: a
  # `data-block-id` and an id on each `<li>`/`<tr>`, its own "+", and the
  # `threads_<id>` / `composer_<id>` containers workstream E targets — and, for
  # a mermaid fence, the wrapper the diagram is drawn into (`wrap_mermaid`).
  #
  # Both can apply at once: a fenced diagram inside a list item is one list
  # block with children *and* a fence to wrap.
  def block_body(annotated, pull_request:, path:)
    children = annotated.children.flat_map(&:self_and_descendants)
    html = annotated.block.html
    return html if children.empty? && !html.include?(MERMAID_FENCE)

    fragment = Nokogiri::HTML5.fragment(html)
    wrap_mermaid(fragment)
    return fragment.to_html.html_safe if children.empty?

    tag_name = children.first.block.type == :table_row ? "tr" : "li"

    # Two children can start on the same source line — `- - a` is one line
    # holding an outer list item and an inner one, and so is the first line of
    # `1. - a`. Keying by start line alone would collapse them onto one block,
    # so every element got the innermost id: duplicate `block_`/`threads_`/
    # `composer_` ids, no gutter on the outer item, and a comment on the inner
    # item appending into the outer one's container.
    #
    # Instead each line keeps a queue, consumed in document order. The renderer
    # walks the same HTML outermost-first, and `css` returns document order, so
    # the outer element takes the outer block and the inner takes the inner.
    pending = children.group_by { |child| child.block.start_line }

    mark_child_tables(fragment) if tag_name == "tr"

    fragment.css("#{tag_name}[data-sourcepos]").each do |element|
      # No block left for this line means we would be guessing. An unmarked
      # item simply offers no gutter, which is better than a wrong anchor.
      child = pending[sourcepos_start_line(element)]&.shift
      next if child.nil?

      decorate_child(element, child, pull_request: pull_request, path: path)
    end

    fragment.to_html.html_safe
  end

  private

  # `Markdown::Highlighter::SKIP` leaves a mermaid fence as a plain
  # `<pre lang="mermaid">`; this is the cheap check for one, matched against the
  # serialized attribute rather than the bare word so a paragraph about mermaids
  # does not cost a parse.
  MERMAID_FENCE = 'lang="mermaid"'

  # Give each mermaid fence somewhere for the client to draw.
  #
  # The `<pre>` is not replaced and not moved out of the block: it carries the
  # `data-sourcepos` the source mapping reads, it is what the gutter "+" anchors
  # a comment to, and with JavaScript off it is still the whole block. The
  # figure is a sibling, empty until `mermaid_controller.js` fills it, and the
  # wrapper's `data-mermaid-state` decides which of the two is on screen.
  #
  # Doing this here rather than in a controller that scans the page is what
  # makes the library's cost conditional: `data-controller="mermaid"` exists on
  # a page with a diagram and on no other, so a pull request without one never
  # asks for the 3.5 MB.
  def wrap_mermaid(fragment)
    fragment.css("pre[lang='mermaid']").each do |pre|
      document = pre.document

      wrapper = node(document, "div", "class" => "md-mermaid",
                                      "data-controller" => "mermaid",
                                      "data-mermaid-state" => "source",
                                      "data-testid" => "mermaid")
      pre.add_next_sibling(wrapper)

      wrapper.add_child(node(document, "div", "class" => "md-mermaid-figure",
                                              "data-mermaid-target" => "figure",
                                              "data-testid" => "mermaid-figure"))
      pre["data-mermaid-target"] = "source"
      wrapper.add_child(pre)
      wrapper.add_child(node(document, "div", "class" => "md-mermaid-error",
                                              "data-mermaid-target" => "error",
                                              "data-testid" => "mermaid-error",
                                              "hidden" => "hidden",
                                              "role" => "status"))
    end
  end

  # A table whose rows are individually commentable needs room in its first
  # column for the row's "+", because the table scrolls and anything placed
  # outside it would be clipped.
  def mark_child_tables(fragment)
    fragment.css("table").each { |table| append_class(table, "md-child-table") }
  end

  def decorate_child(element, annotated, pull_request:, path:)
    block = annotated.block
    document = element.document
    dom_id = block_dom_id(block, Review::Page.file_key(path))

    element["id"] = "block_#{dom_id}"
    element["data-block-id"] = dom_id
    element["data-change"] = annotated.change.to_s
    element["data-commentable"] = annotated.commentable?.to_s
    append_class(element, "md-child")

    if element.name == "tr"
      decorate_row(element, annotated, document: document, pull_request: pull_request, path: path)
    else
      decorate_item(element, annotated, document: document, pull_request: pull_request, path: path)
    end
  end

  # A list item holds its own "+" and its threads, so a comment on one bullet
  # renders under that bullet.
  def decorate_item(element, annotated, document:, pull_request:, path:)
    element.prepend_child(button_node(document, annotated, path: path, modifier: "md-add--child"))
    element.add_child(containers_node(document, annotated, pull_request: pull_request, path: path))
  end

  # A table row can't contain a div, so its threads go in an extra row beneath
  # it, spanning every column. The "+" sits in the row's first cell.
  def decorate_row(element, annotated, document:, pull_request:, path:)
    first_cell = element.at_xpath("./th|./td")
    first_cell&.prepend_child(button_node(document, annotated, path: path, modifier: "md-add--row"))

    cells = element.xpath("./th|./td").size
    thread_row = node(document, "tr", "class" => "md-thread-row",
                                      "data-thread-row-for" => block_dom_id(annotated.block,
                                                                            Review::Page.file_key(path)))
    cell = node(document, "td", "colspan" => [ cells, 1 ].max.to_s)
    cell.add_child(containers_node(document, annotated, pull_request: pull_request, path: path))
    thread_row.add_child(cell)
    element.add_next_sibling(thread_row)
  end

  # The two containers the seam promises for every block: existing threads go
  # in the first, E's composer opens into the second.
  def containers_node(document, annotated, pull_request:, path:)
    id = block_dom_id(annotated.block, Review::Page.file_key(path))
    wrapper = node(document, "div", "class" => "md-child-slots")

    threads = node(document, "div", "id" => "threads_#{id}", "class" => "md-threads")
    rendered = rendered_threads(annotated, pull_request: pull_request, block_id: id)
    threads.add_child(Nokogiri::HTML5.fragment(rendered)) if rendered.present?

    wrapper.add_child(threads)
    wrapper.add_child(node(document, "div", "id" => "composer_#{id}", "class" => "md-composer"))
    wrapper
  end

  def rendered_threads(annotated, pull_request:, block_id:)
    return nil if annotated.threads.blank?

    annotated.threads.map do |thread|
      render("pull_request_files/thread", thread: thread, pull_request: pull_request,
                                          block_id: block_id)
    end.join
  end

  def button_node(document, annotated, path:, modifier:)
    button = node(document, "button", gutter_attributes(annotated, path: path, modifier: modifier,
                                                                   testid: "gutter-add-child"))
    button.content = "+"
    button
  end

  def node(document, name, attributes = {})
    element = Nokogiri::XML::Node.new(name, document)
    attributes.each { |key, value| element[key.to_s] = value.to_s unless value.nil? }
    element
  end

  def append_class(element, name)
    element["class"] = [ element["class"], name ].compact_blank.join(" ")
  end

  # Only the start line is read, so the end-column-0 bleed comrak reports on the
  # last item of a tight list needs no clamp here.
  def sourcepos_start_line(element)
    element["data-sourcepos"].to_s[/\A(\d+):/, 1]&.to_i
  end
end
