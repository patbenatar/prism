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

  # --- the gutter ----------------------------------------------------------

  # The "+" beside a block. Emitted with plain data attributes rather than
  # Stimulus values so the markup does not depend on E's controller having
  # loaded — without JS it is an inert focusable button, with JS it opens the
  # composer.
  def gutter_button(annotated, modifier: nil, testid: "gutter-add")
    content_tag(:button, "+", gutter_attributes(annotated, modifier: modifier, testid: testid))
  end

  def gutter_attributes(annotated, modifier: nil, testid: "gutter-add")
    block = annotated.block
    commentable = annotated.commentable?

    {
      "type" => "button",
      "class" => class_names("md-add", "md-add--muted" => !commentable, modifier => modifier.present?),
      "title" => commentable ? "Comment on this block" : uncommentable_explanation(annotated),
      "aria-label" => commentable ? "Comment on this block" : "Comment on this block (file-level)",
      "data-action" => "composer#open",
      "data-testid" => testid,
      "data-block-id" => block.id,
      "data-block-text" => block.plain_text.to_s.truncate(300),
      "data-start-line" => block.start_line.to_s,
      "data-end-line" => block.end_line.to_s,
      "data-commentable" => commentable.to_s,
      "data-uncommentable-reason" => annotated.uncommentable_reason.to_s,
      "data-anchor" => annotated.anchor&.to_rest&.to_json
    }.compact
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
  # `threads_<id>` / `composer_<id>` containers workstream E targets.
  def block_body(annotated, pull_request:)
    children = annotated.children.flat_map(&:self_and_descendants)
    return annotated.block.html if children.empty?

    fragment = Nokogiri::HTML5.fragment(annotated.block.html)
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

      decorate_child(element, child, pull_request: pull_request)
    end

    fragment.to_html.html_safe
  end

  private

  # A table whose rows are individually commentable needs room in its first
  # column for the row's "+", because the table scrolls and anything placed
  # outside it would be clipped.
  def mark_child_tables(fragment)
    fragment.css("table").each { |table| append_class(table, "md-child-table") }
  end

  def decorate_child(element, annotated, pull_request:)
    block = annotated.block
    document = element.document

    element["id"] = "block_#{block.id}"
    element["data-block-id"] = block.id
    element["data-change"] = annotated.change.to_s
    element["data-commentable"] = annotated.commentable?.to_s
    append_class(element, "md-child")

    if element.name == "tr"
      decorate_row(element, annotated, document: document, pull_request: pull_request)
    else
      decorate_item(element, annotated, document: document, pull_request: pull_request)
    end
  end

  # A list item holds its own "+" and its threads, so a comment on one bullet
  # renders under that bullet.
  def decorate_item(element, annotated, document:, pull_request:)
    element.prepend_child(button_node(document, annotated, modifier: "md-add--child"))
    element.add_child(containers_node(document, annotated, pull_request: pull_request))
  end

  # A table row can't contain a div, so its threads go in an extra row beneath
  # it, spanning every column. The "+" sits in the row's first cell.
  def decorate_row(element, annotated, document:, pull_request:)
    first_cell = element.at_xpath("./th|./td")
    first_cell&.prepend_child(button_node(document, annotated, modifier: "md-add--row"))

    cells = element.xpath("./th|./td").size
    thread_row = node(document, "tr", "class" => "md-thread-row",
                                      "data-thread-row-for" => annotated.block.id)
    cell = node(document, "td", "colspan" => [ cells, 1 ].max.to_s)
    cell.add_child(containers_node(document, annotated, pull_request: pull_request))
    thread_row.add_child(cell)
    element.add_next_sibling(thread_row)
  end

  # The two containers the seam promises for every block: existing threads go
  # in the first, E's composer opens into the second.
  def containers_node(document, annotated, pull_request:)
    id = annotated.block.id
    wrapper = node(document, "div", "class" => "md-child-slots")

    threads = node(document, "div", "id" => "threads_#{id}", "class" => "md-threads")
    rendered = rendered_threads(annotated, pull_request: pull_request)
    threads.add_child(Nokogiri::HTML5.fragment(rendered)) if rendered.present?

    wrapper.add_child(threads)
    wrapper.add_child(node(document, "div", "id" => "composer_#{id}", "class" => "md-composer"))
    wrapper
  end

  def rendered_threads(annotated, pull_request:)
    return nil if annotated.threads.blank?

    annotated.threads.map do |thread|
      render("pull_request_files/thread", thread: thread, pull_request: pull_request,
                                          block_id: annotated.block.id)
    end.join
  end

  def button_node(document, annotated, modifier:)
    button = node(document, "button", gutter_attributes(annotated, modifier: modifier,
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
