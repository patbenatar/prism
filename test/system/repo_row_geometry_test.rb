# frozen_string_literal: true

require "application_system_test_case"

# The repository row is two elements — a link, and the pin toggle's form
# beside it — inside one wrapper that draws the hairline. This asserts that
# the seam does not show.
#
# It measures rather than asserting a class, because the bug it pins was
# invisible to markup: `button_to` wraps its button in a form, that form was
# left in the flow as an empty `inline-block`, and an empty inline-block still
# generates a line box — 25px of dead space between the bottom of the row you
# could hover and the hairline under it. Nothing about the classes on the page
# was wrong. Only the boxes were.
class RepoRowGeometryTest < ApplicationSystemTestCase
  # Every measurement the assertions need, in one round trip: where the
  # wrapper's border box is, where the link inside it ends, and where the pin
  # toggle's form sits.
  MEASURE = <<~JS
    (() => [...document.querySelectorAll('[data-testid=repo-row]')].map(row => {
      const link = row.querySelector('a.row-link');
      const form = row.querySelector('form');
      const r = row.getBoundingClientRect();
      const l = link.getBoundingClientRect();
      const f = form.getBoundingClientRect();
      const border = parseFloat(getComputedStyle(row).borderBottomWidth);
      return {
        name: link.innerText.split("\\n")[0],
        border: border,
        // The band between the bottom of the hoverable link and the hairline.
        deadBand: (r.bottom - border) - l.bottom,
        topOffset: l.top - r.top,
        widthDelta: r.width - l.width,
        // The star should read as centred on the row a reader sees, which is
        // the link — not on a wrapper that is taller than it.
        starOffCentre: ((f.top + f.bottom) / 2) - ((l.top + l.bottom) / 2)
      };
    }))()
  JS

  setup do
    @user = users(:prism_dev)
    stub_github_get("/user/repos", body: four_repos)
    sign_in_as(@user)
    visit repos_path
  end

  test "every row's hairline sits against the bottom of its hover target, at 1440 and at 390" do
    # A pinned section, the boundary between the two panels, and rows both
    # with and without a description — the four shapes a row comes in.
    find("[data-testid=repo-row]", text: "scratchpad").find("[data-testid=pin-button]").click
    assert_selector "[data-testid=pinned-repo-list]"

    [ [ 1440, 900 ], [ 390, 844 ] ].each do |width, height|
      resize_window(width, height)
      rows = page.evaluate_script(MEASURE)

      assert_equal 4, rows.size, "expected the pinned row and three unpinned ones at #{width}px"

      rows.each do |row|
        where = "#{row['name']} at #{width}px"

        assert_in_delta 0, row["deadBand"], 0.5,
                        "#{where}: #{row['deadBand'].round(1)}px of dead space between the row " \
                        "you can hover and the hairline below it"
        assert_in_delta 0, row["topOffset"], 0.5, "#{where}: the link does not start at the row's top edge"
        assert_in_delta 0, row["widthDelta"], 0.5, "#{where}: the link is not as wide as the row"
        assert_in_delta 0, row["starOffCentre"], 1.0,
                        "#{where}: the pin toggle is #{row['starOffCentre'].round(1)}px off the row's centre"
      end
    end
  end

  # Highlighting is read through `:focus-visible` rather than the pointer.
  # Tailwind compiles every `hover:` utility inside `@media (hover: hover)`,
  # and headless Chromium reports no hovering pointer, so a hover fill is
  # never painted here at all — while `.row-link:focus-visible` sets the same
  # two declarations, unwrapped. What is being measured is the *box* the
  # highlight covers, and that is the same box either way.
  #
  # Nothing may be clicked before the focus: Chrome only treats a focus as
  # "visible" when the last interaction was not a pointer.
  test "the highlight fills the row right up to the hairline" do
    link = find("[data-testid=repo-row]", text: "docs-site").find("a.row-link")

    assert_equal TRANSPARENT, background(link), "a row should be quiet until it is pointed at or focused"

    page.execute_script("arguments[0].focus()", link)
    lit = settled { background(link) }

    assert_not_equal TRANSPARENT, lit, "the row was not filled"
    assert_equal "1", settled { tick_opacity(link) }, "the row's brand tick did not appear"

    painted = page.evaluate_script(<<~JS, link)
      (() => {
        const link = arguments[0];
        const row = link.closest('[data-testid=repo-row]');
        const l = link.getBoundingClientRect(), r = row.getBoundingClientRect();
        return { bottom: (r.bottom - parseFloat(getComputedStyle(row).borderBottomWidth)) - l.bottom,
                 top: l.top - r.top, width: r.width - l.width };
      })()
    JS

    painted.each do |edge, delta|
      assert_in_delta 0, delta, 0.5, "the fill stops #{delta.round(1)}px short of the row's #{edge} edge"
    end
  end

  test "the pointer is still inside the row when it reaches the pin toggle" do
    row = find("[data-testid=repo-row]", text: "docs-site")
    row.find("[data-testid=pin-button]").hover

    # `group-hover:` on the link is what carries the fill across the toggle,
    # and `.group:hover` is the half of that rule the browser will evaluate
    # here — the utility itself is behind the same `@media (hover: hover)` the
    # test above works around. If this ever stops matching, the highlight is
    # dropping out from under the pointer halfway across the row.
    hovered = page.evaluate_script("[...document.querySelectorAll('.group:hover')].length")

    assert_equal 1, hovered
    assert page.evaluate_script("arguments[0].matches('.group:hover')", row),
           "the row did not stay hovered when the pointer reached the pin toggle"
  end

  private

  TRANSPARENT = "rgba(0, 0, 0, 0)"

  def background(node) = page.evaluate_script("getComputedStyle(arguments[0]).backgroundColor", node)

  def tick_opacity(node) = page.evaluate_script("getComputedStyle(arguments[0], '::before').opacity", node)

  # A row fades its fill and its tick in (`transition-colors`,
  # `transition-opacity`), so the value read the instant it lights up is still
  # the one it is leaving. Read until it stops changing.
  def settled
    deadline = Time.now + 2
    value = yield
    loop do
      sleep 0.08
      following = yield
      return following if following == value || Time.now > deadline

      value = following
    end
  end

  def four_repos
    [
      repo_json("acme", "docs-site", 1, description: "Product documentation, written in Markdown.", type: "Organization"),
      repo_json("prism-dev", "scratchpad", 2),
      repo_json("acme", "widgets", 3, description: "A second repository, with a description of its own."),
      repo_json("prism-dev", "notes", 4)
    ]
  end

  def repo_json(owner, name, id, description: nil, type: "User")
    { "id" => id, "name" => name, "full_name" => "#{owner}/#{name}", "private" => false,
      "description" => description, "default_branch" => "main",
      "pushed_at" => "2026-09-18T16:30:00Z", "open_issues_count" => 3,
      "html_url" => "https://github.com/#{owner}/#{name}",
      "owner" => { "login" => owner, "avatar_url" => "https://example.test/a.png", "type" => type } }
  end
end
