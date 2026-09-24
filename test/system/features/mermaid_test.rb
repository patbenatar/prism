# frozen_string_literal: true

require "application_system_test_case"

# A ```mermaid fence, drawn.
#
# GitHub renders one as a diagram; Prism used to show the source, which is the
# thing this product exists to fix. The rules this suite holds down are the
# ones that made it hard:
#
#   * the diagram appears without the browser blocking anything — `script-src`
#     and `style-src` are 'self' plus a nonce, and mermaid builds its own
#     <style> elements (see `withNoncedStyles` in mermaid_controller.js);
#   * the block is still a block: gutter, "+", and a comment that anchors to
#     the fence's own lines;
#   * a broken fence is one bad diagram, not a bad page;
#   * a pull request with no diagram in it never fetches the 3.5 MB.
class MermaidTest < ApplicationSystemTestCase
  include FeatureHelpers

  OWNER = FeatureHelpers::FEATURE_OWNER
  REPO = FeatureHelpers::FEATURE_REPO
  NUMBER = FeatureHelpers::FEATURE_NUMBER
  HEAD_SHA = FeatureHelpers::FEATURE_HEAD_SHA

  DIAGRAM_PATH = "docs/architecture.md"
  BROKEN_PATH = "docs/broken.md"
  PLAIN_PATH = "docs/plain.md"
  WIDE_PATH = "docs/wide.md"
  HOSTILE_PATH = "docs/hostile.md"
  RICH_PATH = "docs/how-prism-works.md"

  SCREENSHOTS = Rails.root.join("tmp/screenshots")
  LAPTOP = [ 1440, 1000 ].freeze
  PHONE = [ 390, 844 ].freeze

  # The fence sits on lines 5–10, which is what the comment test asserts the
  # anchor lands on.
  DIAGRAM = <<~MARKDOWN
    # Architecture

    How a review request moves through Prism.

    ```mermaid
    graph TD;
      Webhook-->Queue;
      Queue-->Render;
      Render-->Gutter;
    ```

    The renderer hands each block to the gutter beside it.
  MARKDOWN

  # An edge with nothing on the far side of it, then an arrow starting from
  # nothing — the shape of a half-finished diagram somebody pushed by accident.
  # Mermaid's parser refuses it, which is what the fallback is for.
  BROKEN = <<~MARKDOWN
    # Broken

    ```mermaid
    graph TD
      A -->
      --> ((
    ```

    The prose after a broken diagram still renders.
  MARKDOWN

  # Long labels laid out left to right, so the drawing is wider than a phone.
  WIDE = <<~MARKDOWN
    # Wide

    ```mermaid
    graph LR;
      Repository-->WebhookDelivery;
      WebhookDelivery-->RenderedDocument;
      RenderedDocument-->ReviewerComment;
      ReviewerComment-->GitHubPullRequest;
    ```
  MARKDOWN

  # Everything a diagram could try. This is not hypothetical: mermaid's own CVE
  # history is labels and link syntax, and the fence came out of a repository
  # somebody else controls.
  #
  # Two fences, because they fail differently. The first is valid mermaid and
  # draws — markup in a label, a `javascript:` click, and a node named after one
  # of the page's own elements. The second is the CSS-injection attempt, which
  # mermaid's own parser rejects; it is here so that the rejection is a recorded
  # fact rather than an assumption.
  HOSTILE = <<~MARKDOWN
    # Hostile

    ```mermaid
    graph TD;
      A["<img src=x onerror='window.__pwned=1'>"]-->B;
      B-->pending_tray;
      C["<a href='javascript:window.__pwned=2'>tap</a>"]-->A;
      click A "javascript:window.__pwned=3" "tooltip";
    ```

    ```mermaid
    graph TD;
      D-->E;
      classDef evil fill:#fff}body{display:none;
      class E evil;
    ```

    ```mermaid
    flowchart TD
        F[One] --> G[Two]
        style F position:fixed,z-index:99999,fill:#00ff00
        style G cursor:pointer,stroke:#ff0000
    ```
  MARKDOWN

  # The shape that broke in production (patbenatar/prism#19): a decision
  # diamond, a second flowchart, and a sequence diagram — three renderers, three
  # stylesheets, on one page.
  RICH = <<~MARKDOWN
    # How Prism works

    ```mermaid
    flowchart TD
        A[Reviewer opens a pull request] --> B[Prism fetches the files]
        B --> C{Is the block's line in the diff?}
        C -->|Yes| D[Gutter offers a comment]
        C -->|No| E[Gutter offers a file-level comment]
    ```

    ```mermaid
    flowchart LR
        S[Markdown source] --> P[Parse to a tree]
        P --> R[Rendered, commentable page]
    ```

    ```mermaid
    sequenceDiagram
        participant G as GitHub
        participant P as Prism
        G->>P: pull_request event
        P->>P: Verify signature
        P-->>G: 200, immediately
    ```
  MARKDOWN

  PLAIN = <<~MARKDOWN
    # Plain

    Nothing here draws anything.

    ```ruby
    puts "hello"
    ```
  MARKDOWN

  setup do
    @user = users(:prism_dev)
    FileUtils.mkdir_p(SCREENSHOTS)
    resize_window(*LAPTOP)

    stub_feature_mentionables(owner: OWNER, repo: REPO)
    stub_github_markdown(fixture: "markdown.html")
    stub_feature_review_threads([])
  end

  # ── It draws ─────────────────────────────────────────────────────────────

  test "a mermaid fence renders as an svg, and the browser blocks nothing" do
    open_diagrams

    assert_selector "##{key(DIAGRAM_PATH)} [data-testid=mermaid-figure] svg", wait: 20
    figure = find("##{key(DIAGRAM_PATH)} [data-testid=mermaid-figure]")

    # It is a real diagram, not an empty frame: every node in the fence is a
    # label in the picture.
    %w[Webhook Queue Render Gutter].each { |label| assert_text figure, label }

    # And the source is still there, one click away.
    assert_selector "##{key(DIAGRAM_PATH)} pre[lang=mermaid]", visible: :all
    assert_equal "diagram", find("##{key(DIAGRAM_PATH)} [data-testid=mermaid]")["data-mermaid-state"]

    assert_no_csp_violations
  end

  test "nothing in the diagram can execute: no script, no handler, no javascript: url" do
    open_diagrams
    assert_selector "[data-testid=mermaid-figure] svg", wait: 20

    svg = find("[data-testid=mermaid-figure] svg")
    assert_empty page.evaluate_script(<<~JS, svg)
      (() => {
        const bad = []
        for (const element of arguments[0].querySelectorAll("*")) {
          if (element.localName.toLowerCase() === "script") bad.push("script")
          for (const attribute of element.attributes) {
            const key = attribute.name.toLowerCase()
            if (key.startsWith("on")) bad.push(attribute.name)
            // A style attribute is how mermaid paints; what must not be in one
            // is a reference to anything off this page.
            if (key === "style" && /url\\(\\s*["']?(?!#)/i.test(attribute.value)) {
              bad.push(`off-site url in style: ${attribute.value}`)
            }
            if (/javascript:/i.test(attribute.value)) bad.push(attribute.value)
          }
        }
        return bad
      })()
    JS

    # Every id the diagram carries is namespaced, for the reason
    # Markdown::Sanitizer namespaces the document's: a repository must not be
    # able to name an element `pending_tray` and have the page find it.
    assert_empty page.evaluate_script(<<~JS, svg)
      (() => {
        const ids = [arguments[0], ...arguments[0].querySelectorAll("[id]")]
          .map((element) => element.getAttribute("id"))
          .filter(Boolean)
        return ids.filter((id) => !id.startsWith("user-content-"))
      })()
    JS
  end

  test "the toggle swaps the diagram for the source it was drawn from" do
    open_diagrams
    assert_selector "[data-testid=mermaid-figure] svg", wait: 20

    click_on "Show source"
    assert_selector "##{key(DIAGRAM_PATH)} pre[lang=mermaid]", text: "graph TD", visible: true
    assert_no_selector "[data-testid=mermaid-figure] svg", visible: true

    click_on "Show diagram"
    assert_selector "[data-testid=mermaid-figure] svg", visible: true
  end

  # ── It is still a block ──────────────────────────────────────────────────

  test "a rendered diagram's block keeps its gutter and takes a comment" do
    open_diagrams

    block = find("##{key(DIAGRAM_PATH)} [data-testid=md-block][data-block-type=code_block]")
    assert_selector block, "[data-testid=mermaid-figure] svg", wait: 20

    # The diagram did not eat the gutter: the block still knows the lines the
    # fence occupies, and still offers the "+".
    assert_equal "5", block["data-start-line"]
    assert_equal "10", block["data-end-line"]
    assert_equal "true", block["data-commentable"]
    assert_selector block, ".md-add", visible: :all

    thread = feature_thread(
      node_id: "PRRT_diagram", path: DIAGRAM_PATH, line: 10, start_line: 5,
      comments: [ feature_comment(node_id: "PRRC_diagram", body: "Queue should fan out.") ]
    )
    stub_github_graphql(:AddThread, data: { addPullRequestReviewThread: { thread: thread } })
    stub_feature_review_threads([ thread ])

    block_id = comment_on_block(block, body: "Queue should fan out.")

    assert_selector "##{"threads_#{block_id}"} [data-testid=thread]",
                    text: "Queue should fan out.", wait: 5

    expect_github_received(:AddThread) do |vars|
      input = vars["input"]
      input["path"] == DIAGRAM_PATH && input["startLine"] == 5 && input["line"] == 10 &&
        input["side"] == "RIGHT"
    end
  end

  test "a diagram that tries everything lands on the page inert" do
    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER,
                              files_body: [ added_file(HOSTILE_PATH) ], reviews_body: [])
    stub_feature_contents(HOSTILE_PATH, HEAD_SHA, HOSTILE, owner: OWNER, repo: REPO)
    sign_in_for_feature(@user)
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: HOSTILE_PATH)

    # The first fence has to actually draw, or the assertions below prove
    # nothing; the second is expected to be refused.
    assert_selector "[data-testid=mermaid-figure] svg", wait: 20
    assert_selector "[data-testid=mermaid-error]", visible: true, wait: 20

    assert_nil page.evaluate_script("window.__pwned ?? null"),
               "nothing in a diagram may execute"

    findings = page.evaluate_script(<<~JS)
      (() => {
        const bad = []
        const roots = [...document.querySelectorAll("[data-testid=mermaid-figure] svg")]
        if (roots.length === 0) return ["no diagram drew at all"]
        for (const element of roots.flatMap((svg) => [svg, ...svg.querySelectorAll("*")])) {
          const name = element.localName.toLowerCase()
          if (["script", "iframe", "object", "embed"].includes(name)) bad.push(`element ${name}`)
          for (const attribute of element.attributes) {
            const key = attribute.name.toLowerCase()
            if (key.startsWith("on")) bad.push(`handler ${key}`)
            // A style attribute is how mermaid paints, so it is allowed — but
            // only declarations that paint, and only references into this same
            // diagram. See STYLE_PROPERTIES in mermaid_controller.js.
            if (key === "style" && /url\\(\\s*["']?(?!#)/i.test(attribute.value)) {
              bad.push(`off-site url in style: ${attribute.value}`)
            }
            if (/^\\s*(javascript|data|blob|vbscript):/i.test(attribute.value)) {
              bad.push(`url ${attribute.value}`)
            }
            if (key === "id" && !attribute.value.startsWith("user-content-")) {
              bad.push(`bare id ${attribute.value}`)
            }
          }
          // Nothing a diagram declares may take it out of its own frame.
          if (getComputedStyle(element).position !== "static") {
            bad.push(`positioned ${name}`)
          }
        }
        return bad
      })()
    JS

    assert_empty findings

    # The page's own elements are still the page's. A node called
    # `pending_tray` must not be what `getElementById` finds.
    assert_equal "DIV", page.evaluate_script(
      "document.getElementById('pending_tray')?.tagName ?? 'MISSING'"
    )

    # And the diagram's stylesheet cannot reach out of the diagram: the body is
    # still laid out as the layout says, which
    # `classDef evil fill:#fff}body{display:none` was trying to change.
    assert_equal "flex", computed_style("body", "display")

    assert_no_csp_violations
  end

  # ── It fails safely ──────────────────────────────────────────────────────

  test "a broken fence falls back to its source with a visible note, and the page survives" do
    open_diagrams

    broken = find("##{key(BROKEN_PATH)} [data-testid=mermaid]")
    note = broken.find("[data-testid=mermaid-error]", wait: 20)

    assert note.visible?, "a diagram that could not be drawn has to say so"
    assert_match(/couldn't draw this diagram/i, note.text)

    # The source is what you are left looking at, not a blank frame.
    assert_selector broken, "pre[lang=mermaid]", text: "graph TD", visible: true
    assert_no_selector broken, "svg"
    assert_equal "source", broken["data-mermaid-state"]

    # One bad fence, not a bad page: the prose around it and the good diagram
    # in the other file are both fine.
    assert_text "The prose after a broken diagram still renders."
    assert_selector "##{key(DIAGRAM_PATH)} [data-testid=mermaid-figure] svg", wait: 20

    # And the broken block is still a block.
    assert_selector "##{key(BROKEN_PATH)} [data-testid=md-block] .md-add", visible: :all

    assert_no_csp_violations
  end

  # ── It costs nothing when there is nothing to draw ───────────────────────

  test "a pull request with no diagram in it never fetches mermaid" do
    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER,
                              files_body: [ added_file(PLAIN_PATH) ], reviews_body: [])
    stub_feature_contents(PLAIN_PATH, HEAD_SHA, PLAIN, owner: OWNER, repo: REPO)
    sign_in_for_feature(@user)
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: PLAIN_PATH)

    assert_selector "[data-testid=rendered-file] pre", text: 'puts "hello"'
    assert_no_selector "[data-controller~=mermaid]", visible: :all

    assert_equal 0, mermaid_requests,
                 "a page with no diagram must not ask for the library"
    assert_no_csp_violations
  end

  test "however many diagrams a page holds, the library is fetched once" do
    open_diagrams
    assert_selector "[data-testid=mermaid-figure] svg", wait: 20
    assert_selector "[data-testid=mermaid-error]", visible: true, wait: 20

    assert_equal 1, mermaid_requests
  end

  test "a diagram wider than a phone scrolls in its own frame, not the page" do
    resize_window(*PHONE)
    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER,
                              files_body: [ added_file(WIDE_PATH) ], reviews_body: [])
    stub_feature_contents(WIDE_PATH, HEAD_SHA, WIDE, owner: OWNER, repo: REPO)
    sign_in_for_feature(@user)
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: WIDE_PATH)

    assert_selector "[data-testid=mermaid-figure] svg", wait: 20

    # The frame scrolls, exactly as a wide <pre> or a wide table does…
    scroll, client = page.evaluate_script(<<~JS)
      (() => {
        const figure = document.querySelector("[data-testid=mermaid-figure]")
        return [figure.scrollWidth, figure.clientWidth]
      })()
    JS
    assert_operator scroll, :>, client, "a diagram too wide for the column has to scroll"

    # …and the page does not. DESIGN §4: no horizontal overflow on a phone.
    overflow = page.evaluate_script(
      "document.documentElement.scrollWidth - document.documentElement.clientWidth"
    )
    assert_operator overflow, :<=, 1, "the page scrolls sideways at 390px"
  end

  # ── It is actually painted ───────────────────────────────────────────────
  #
  # This pair is the regression for the bug that shipped: a diagram whose
  # stylesheet the browser refused keeps every bit of its geometry and loses all
  # of its paint — black boxes, black labels, and labels drawn in a font other
  # than the one they were measured in. Nothing in a screenshot review caught
  # it, and nothing that asserts "an <svg> exists" ever could.

  test "a diagram is painted in the page's own tokens, in both schemes" do
    open_rich
    assert_painted(:light)

    with_color_scheme(:dark) do
      visit_rich
      assert_painted(:dark)
    end
  end

  test "a diagram reached the way a reviewer reaches it is painted too" do
    # The bug in production. Every earlier test arrived by `visit` — a real
    # navigation, so a new document whose CSP and `csp-nonce` meta agree. A
    # reviewer arrives by clicking, which is a Turbo Drive visit: <body> is
    # swapped and the meta is rewritten to the new response's nonce, while the
    # policy being enforced is still the original document's. Stamping the
    # meta's value then gets every diagram stylesheet blocked.
    stub_rich
    sign_in_for_feature(@user)
    visit repos_path
    assert_selector "body"

    turbo_visit(repo_pull_markdown_path(owner: OWNER, repo: REPO, number: NUMBER,
                                        anchor: key(RICH_PATH)))
    assert_painted(:light)
  end

  test "a diagram reached by a Turbo visit is painted in dark mode too" do
    stub_rich
    sign_in_for_feature(@user)

    with_color_scheme(:dark) do
      visit repos_path
      assert_selector "body"
      turbo_visit(repo_pull_markdown_path(owner: OWNER, repo: REPO, number: NUMBER,
                                          anchor: key(RICH_PATH)))
      assert_painted(:dark)
    end
  end

  # ── It follows the colour scheme ─────────────────────────────────────────

  test "the diagram is drawn in the active colour scheme and survives a switch" do
    with_color_scheme(:dark) do
      open_diagrams
      assert_selector "[data-testid=mermaid-figure] svg", wait: 20
      dark = diagram_text_color

      # The ink in the diagram is the page's ink, which is the light side of
      # the token's `light-dark()` pair only in light mode.
      assert_equal computed_style("[data-testid=rendered-file] p", "color"), dark

      # Switching while the page is open redraws it rather than leaving a dark
      # diagram on a light page.
      with_color_scheme(:light) do
        assert_selector "[data-testid=mermaid-figure] svg"
        light = nil
        assert_eventually("the diagram redraws when the scheme changes") do
          light = diagram_text_color
          light != dark
        end
        assert_equal computed_style("[data-testid=rendered-file] p", "color"), light
      end
    end

    assert_no_csp_violations
  end

  # ── The pictures ─────────────────────────────────────────────────────────

  test "screenshots of a rendered diagram, and of one that could not be drawn" do
    stub_diagrams
    sign_in_for_feature(@user)

    [ [ "laptop", LAPTOP ], [ "phone", PHONE ] ].each do |label, size|
      [ [ "light", nil ], [ "dark", :dark ] ].each do |theme, scheme|
        shoot_diagrams(label, size, theme, scheme)
      end
    end

    assert_operator Dir[SCREENSHOTS.join("mermaid-*.png")].size, :>=, 8
  end

  private

  def key(path) = Review::Page.file_key(path)

  # Every diagram on the page took the page's colours, and its labels sit where
  # the boxes are. `scheme` only names the expectation for the failure message —
  # the values come from the stylesheet either way.
  def assert_painted(scheme)
    assert_selector "[data-testid=mermaid-figure] svg", count: 3, wait: 30

    sunk = token_color("--color-sunk")
    ink = token_color("--color-ink")
    paint = diagram_paint

    assert_equal 3, paint.size, "every fence should have drawn"

    paint.each_with_index do |diagram, index|
      assert diagram["stylesheetApplied"],
             "#{scheme}: diagram #{index}'s stylesheet was refused, so it is drawing in " \
             "SVG's default paint — black boxes with black labels"
    end

    # The flowcharts are the two with nodes; a sequence diagram has none, and
    # its stylesheet is covered above.
    paint.first(2).each_with_index do |diagram, index|
      assert_equal sunk, diagram["nodeFill"],
                   "#{scheme}: diagram #{index}'s nodes should be filled with --color-sunk"
      assert_equal ink, diagram["labelFill"],
                   "#{scheme}: diagram #{index}'s labels should be drawn in --color-ink"
      refute_equal diagram["nodeFill"], diagram["labelFill"],
                   "#{scheme}: diagram #{index}'s label is the same colour as the box behind it"
      refute_equal diagram["figureBackground"], diagram["nodeFill"],
                   "#{scheme}: diagram #{index}'s nodes are invisible against the frame"
      refute_equal "rgb(0, 0, 0)", diagram["nodeFill"],
                   "#{scheme}: diagram #{index} fell back to SVG's default black"
      assert diagram["labelInsideNode"],
             "#{scheme}: diagram #{index}'s label sits outside its own box " \
             "(#{diagram["labelRect"].inspect} vs #{diagram["nodeRect"].inspect}) — it was " \
             "measured in one font and drawn in another"
    end

    assert_self_messages_unfilled(scheme)
  end

  # A sequence diagram's self-message is an arc that leaves a lifeline and comes
  # back to it: stroked, and filled with nothing.
  #
  # Mermaid says so with `style="fill: none;"` on the path and in no other way —
  # its `.messageLine0` rule sets only the stroke. Dropping the `style`
  # attribute therefore left the arc inheriting `fill` from the diagram's root
  # rule, which drew each self-message as a solid blob the colour of the
  # document's ink.
  def assert_self_messages_unfilled(scheme)
    loops = page.evaluate_script(<<~JS)
      [...document.querySelectorAll("[data-testid=mermaid-figure] svg")]
        .flatMap((svg) => [...svg.querySelectorAll("path, line")])
        .filter((el) => {
          const from = el.getAttribute("data-from")
          return from && from === el.getAttribute("data-to")
        })
        .map((el) => ({
          fill: getComputedStyle(el).fill,
          stroke: getComputedStyle(el).stroke,
          style: el.getAttribute("style")
        }))
    JS

    refute_empty loops, "#{scheme}: the fixture should contain a self-message to check"

    loops.each do |loop|
      assert_equal "none", loop["fill"],
                   "#{scheme}: a self-message should be an unfilled arc, and this one is " \
                   "filled with #{loop["fill"]} (style=#{loop["style"].inspect})"
      refute_equal "none", loop["stroke"],
                   "#{scheme}: a self-message still has to be drawn"
    end
  end

  # What the browser actually painted, read back per diagram.
  def diagram_paint
    page.evaluate_script(<<~JS)
      [...document.querySelectorAll("[data-testid=mermaid-figure]")].map((figure) => {
        const svg = figure.querySelector("svg")
        if (!svg) return { stylesheetApplied: false }
        const style = svg.querySelector("style")
        const shape = svg.querySelector("g.node .label-container, g.node rect")
        const label = svg.querySelector("g.node .nodeLabel, g.node text")
        const sb = shape && shape.getBoundingClientRect()
        const lb = label && label.getBoundingClientRect()
        return {
          stylesheetApplied: !!(style && style.sheet && style.sheet.cssRules.length > 0),
          nodeFill: shape ? getComputedStyle(shape).fill : null,
          labelFill: label ? getComputedStyle(label).fill : null,
          figureBackground: getComputedStyle(figure).backgroundColor,
          labelInsideNode: !!(sb && lb && lb.left >= sb.left - 2 && lb.right <= sb.right + 2),
          nodeRect: sb ? [Math.round(sb.left), Math.round(sb.right)] : null,
          labelRect: lb ? [Math.round(lb.left), Math.round(lb.right)] : null
        }
      })
    JS
  end

  # A design token as the browser resolved it — each one is a `light-dark()`
  # pair, so it has to be painted before it means anything.
  def token_color(name)
    page.evaluate_script(<<~JS)
      (() => {
        const el = document.createElement("span")
        el.style.color = "var(#{name})"
        document.body.appendChild(el)
        const value = getComputedStyle(el).color
        el.remove()
        return value
      })()
    JS
  end

  # A Turbo Drive visit — <body> swapped, document kept — rather than a browser
  # navigation. This is how every reviewer moves through the app.
  def turbo_visit(path)
    page.execute_script("window.Turbo.visit(arguments[0])", path)
  end

  def stub_rich
    stub_github_get("/user/repos", fixture: :repos)
    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER,
                              files_body: [ added_file(RICH_PATH) ], reviews_body: [])
    stub_feature_contents(RICH_PATH, HEAD_SHA, RICH, owner: OWNER, repo: REPO)
  end

  def open_rich
    stub_rich
    sign_in_for_feature(@user)
    visit_rich
  end

  def visit_rich
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: RICH_PATH)
  end



  # The pull request under review: one file with a good diagram, one with a
  # broken fence. Both in the same request on purpose — "a broken diagram must
  # not break the other files" is only worth asserting with another file there.
  def open_diagrams
    stub_diagrams
    sign_in_for_feature(@user)
    visit_diagrams
  end

  def stub_diagrams
    stub_feature_pull_request(owner: OWNER, repo: REPO, number: NUMBER,
                              files_body: [ added_file(DIAGRAM_PATH), added_file(BROKEN_PATH) ],
                              reviews_body: [])
    stub_feature_contents(DIAGRAM_PATH, HEAD_SHA, DIAGRAM, owner: OWNER, repo: REPO)
    stub_feature_contents(BROKEN_PATH, HEAD_SHA, BROKEN, owner: OWNER, repo: REPO)
  end

  def visit_diagrams
    open_pull_file(owner: OWNER, repo: REPO, number: NUMBER, path: DIAGRAM_PATH)
  end

  # An added file: every line is in the diff, so every block is commentable.
  def added_file(path)
    body = { DIAGRAM_PATH => DIAGRAM, BROKEN_PATH => BROKEN, PLAIN_PATH => PLAIN,
             WIDE_PATH => WIDE, HOSTILE_PATH => HOSTILE, RICH_PATH => RICH }.fetch(path)
    lines = body.lines.map(&:chomp)
    patch = ([ "@@ -0,0 +1,#{lines.size} @@" ] + lines.map { |line| "+#{line}" }).join("\n")

    { "filename" => path, "status" => "added", "additions" => lines.size, "deletions" => 0,
      "changes" => lines.size, "patch" => patch,
      "blob_url" => "https://github.com/#{OWNER}/#{REPO}/blob/#{HEAD_SHA}/#{path}" }
  end

  # What the browser actually went and got. `performance` sees every request
  # the page made, which is the only honest way to assert that a page with no
  # diagram on it did not quietly pull 3.5 MB.
  def mermaid_requests
    page.evaluate_script(<<~JS)
      performance.getEntriesByType("resource")
        .filter((entry) => /\\/assets\\/mermaid\\.min-/.test(entry.name)).length
    JS
  end

  # The fill the diagram paints its labels in, read back as a used value.
  def diagram_text_color
    computed_style("[data-testid=mermaid-figure] svg text", "fill") ||
      computed_style("[data-testid=mermaid-figure] svg .nodeLabel", "color")
  end

  # Capybara's waiting is for selectors; this is for a value that settles.
  def assert_eventually(message, timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return if yield
      flunk(message) if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.1
    end
  end

  def shoot_diagrams(label, size, theme, scheme)
    resize_window(*size)
    capture = lambda do
      visit_diagrams
      assert_selector "##{key(DIAGRAM_PATH)} [data-testid=mermaid-figure] svg", wait: 20
      save_screenshot(SCREENSHOTS.join("mermaid-#{label}-#{theme}.png"))

      find("##{key(BROKEN_PATH)} [data-testid=mermaid-error]", wait: 20)
      scroll_to(find("##{key(BROKEN_PATH)} [data-testid=mermaid]"))
      save_screenshot(SCREENSHOTS.join("mermaid-broken-#{label}-#{theme}.png"))
    end

    scheme ? with_color_scheme(scheme) { capture.call } : capture.call
  end
end
