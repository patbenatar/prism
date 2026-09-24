# frozen_string_literal: true

require "application_system_test_case"

# Dark mode mirrors the device, so there is nothing in the app to click and
# nothing in the DOM that says which theme is on: `@media
# (prefers-color-scheme: dark)` resolves `color-scheme` on :root, and that in
# turn resolves every `light-dark()` pair in the token block. The only honest
# check is to make the browser prefer dark and read back the colours the page
# actually computed. `ColorSchemeHelpers` (test/support) emulates the media
# feature over CDP; docs/testing.md explains why that is the only way.
#
# This file pins the mechanism. The screenshot sweep beside it
# (test/system/theme_screenshots_test.rb) is the part a designer looks at.
class DarkModeTest < ApplicationSystemTestCase
  include FeatureHelpers

  # The two anchors of the palette, from DESIGN.md §2. Pinned exactly: if the
  # token block silently stops resolving — a `color-scheme` that got dropped,
  # a `light-dark()` a build step flattened, a stray `@media` around the
  # colours — every ratio in §2's dark table is wrong and nothing else in the
  # suite would notice.
  LIGHT_CANVAS = "rgb(242, 243, 248)"
  DARK_CANVAS  = "rgb(14, 16, 32)"
  LIGHT_INK    = "rgb(22, 24, 43)"
  DARK_INK     = "rgb(230, 233, 244)"

  DARK_CANVAS_RGB = [ 14, 16, 32 ].freeze

  SPECTRUM = %w[brand pending added modified removed resolved].freeze

  REVIEW_PATH = "docs/guide.md"

  setup do
    @user = users(:prism_dev)
    stub_github_get("/user/repos", fixture: :repos)
  end

  test "a dark device gets the dark canvas, and a light one the light canvas" do
    visit sign_in_path
    assert_equal LIGHT_CANVAS, computed_style("body", "background-color")
    assert_equal LIGHT_INK, computed_style("body", "color")

    with_color_scheme(:dark) do
      visit sign_in_path
      assert page_prefers_dark?, "the browser did not report a dark preference"
      assert_equal DARK_CANVAS, computed_style("body", "background-color")
      assert_equal DARK_INK, computed_style("body", "color")
    end

    # And back, so the device preference really is the only thing driving it.
    visit sign_in_path
    assert_equal LIGHT_CANVAS, computed_style("body", "background-color")
  end

  test "color-scheme follows the device, so native controls and scrollbars do too" do
    visit sign_in_path
    assert_equal "light dark", computed_style("html", "color-scheme"),
                 ":root must declare both schemes or light-dark() never resolves"
    assert_equal "light", resolved_color_scheme

    with_color_scheme(:dark) do
      visit sign_in_path
      assert_equal "dark", resolved_color_scheme
    end
  end

  test "data-theme overrides the device in both directions" do
    with_color_scheme(:dark) do
      visit sign_in_path
      assert_equal DARK_CANVAS, computed_style("body", "background-color")

      force_theme("light")
      assert_equal LIGHT_CANVAS, computed_style("body", "background-color"),
                   %(data-theme="light" did not win over a dark device)
      assert_equal "light", resolved_color_scheme
    end

    visit sign_in_path
    force_theme("dark")
    assert_equal DARK_CANVAS, computed_style("body", "background-color"),
                 %(data-theme="dark" did not win over a light device)
    assert_equal "dark", resolved_color_scheme
  end

  test "the review spectrum stays six different colours, all AA on the dark canvas" do
    with_color_scheme(:dark) do
      visit sign_in_path

      colors = SPECTRUM.to_h { |band| [ band, token_color("--color-#{band}") ] }

      assert_equal colors.length, colors.values.uniq.length,
                   "two spectrum bands resolved to the same colour: #{colors.inspect}"

      colors.each do |band, color|
        assert_operator contrast_with_dark_canvas(color), :>=, 4.5,
                        "#{band} (#{color}) is below AA on the dark canvas — see DESIGN.md §2"
        assert_operator contrast(color, token_color("--color-#{band}-soft")), :>=, 4.5,
                        "#{band} (#{color}) is below AA on its own soft fill — see DESIGN.md §2"
      end
    end
  end

  test "every token and the seam change with the theme" do
    sign_in_as(@user)
    visit repos_path
    assert_selector "[data-testid=top-bar]"
    light = theme_snapshot

    with_color_scheme(:dark) do
      visit repos_path
      assert_selector "[data-testid=top-bar]"
      dark = theme_snapshot

      unchanged = light.select { |name, value| dark[name] == value }
      assert_empty unchanged,
                   "these carried their paper value onto the dark canvas: #{unchanged.keys.join(', ')}"

      refute_equal computed_style(".topbar-seam", "opacity"), light[:seam_opacity],
                   "the spectrum seam kept its paper opacity on the dark canvas"
    end
  end

  test "no screen paints a pale panel on the dark canvas" do
    sign_in_as(@user)
    stub_repo_screens

    with_color_scheme(:dark) do
      [ sign_in_path,
        repos_path,
        repo_pulls_path(owner: "acme", repo: "docs-site"),
        repo_pull_path(owner: "acme", repo: "docs-site", number: 42),
        repo_pull_markdown_path(owner: "acme", repo: "docs-site", number: 42) ].each do |path|
        visit path

        pale = pale_fills
        assert_empty pale,
                     "#{path} still paints #{pale.length} element(s) a pale neutral in dark mode — " \
                     "they are hardcoding a colour instead of reading a token:\n#{pale.first(8).join("\n")}"
      end
    end
  end

  private

  # The review screen is the richest one in the app, and the only place the
  # gutter, the removed strips, the threads and the tray are all on screen at
  # once. Same fixtures ThreadPlacementTest uses; `stub_feature_pull_request`
  # already answers the contents endpoint for every Markdown file on the page.
  BASE_GUIDE = <<~MARKDOWN
    # Guide

    Existing text.

    Some filler so the line numbers line up with the patch fixture.

    More filler.

    ## Section
    Prose here.
    Old line.
    Tail.
  MARKDOWN

  def stub_repo_screens
    stub_github_get("/repos/acme/docs-site", fixture: :repo)
    stub_github_get("/repos/acme/docs-site/pulls", fixture: :pulls)
    stub_feature_pull_request
    stub_feature_mentionables
    stub_github_markdown(fixture: "markdown.html")
    stub_feature_contents(REVIEW_PATH, FeatureHelpers::FEATURE_HEAD_SHA, github_fixture_raw("guide.md"))
    stub_feature_contents(REVIEW_PATH, FeatureHelpers::FEATURE_BASE_SHA, BASE_GUIDE)
    stub_github_graphql(:ReviewThreads, fixture: :review_threads)
  end

  # Every colour token plus the two scalars dark mode also needs, as the
  # browser resolved them on this page.
  def theme_snapshot
    names = %w[canvas surface sunk ink ink-soft ink-faint line line-strong] +
            SPECTRUM.flat_map { |band| [ band, "#{band}-soft" ] } +
            %w[on-brand]

    # `--tint-strength` used to be here. The tint behind changed blocks was
    # removed (2026-09-24) because it made the Markdown harder to read; the
    # gutter change bars carry the state on their own now, in both schemes.
    snapshot = names.to_h { |name| [ name.to_sym, token_color("--color-#{name}") ] }
    snapshot[:seam_opacity] = computed_style(".topbar-seam", "opacity")
    snapshot.compact
  end

  # `color-scheme` computes to whatever was declared ("light dark"), so the
  # side the browser actually picked is only visible in what it does with it.
  # This canary is exactly what a token is: a `light-dark()` the page has to
  # resolve.
  def resolved_color_scheme
    page.evaluate_script(<<~JS)
      (() => {
        const el = document.createElement('span');
        el.style.color = 'light-dark(rgb(1, 1, 1), rgb(2, 2, 2))';
        document.body.appendChild(el);
        const value = getComputedStyle(el).color;
        el.remove();
        return value === 'rgb(2, 2, 2)' ? 'dark' : 'light';
      })()
    JS
  end

  def force_theme(theme)
    page.execute_script(%(document.documentElement.setAttribute('data-theme', #{theme.to_json})))
  end

  # A custom property reads back unresolved (`light-dark(#f2f3f8,#0e1020)`),
  # because substitution happens where it is used. Painting it onto a throwaway
  # element is what forces the browser to pick a side.
  def token_color(name)
    page.evaluate_script(<<~JS)
      (() => {
        const el = document.createElement('span');
        el.style.color = 'var(#{name})';
        document.body.appendChild(el);
        const value = getComputedStyle(el).color;
        el.remove();
        return value;
      })()
    JS
  end

  # A pale NEUTRAL fill on a dark page is either a hardcoded colour or a token
  # with no dark value. Saturated fills are exempt: `bg-brand` is a pale violet
  # in dark mode on purpose, and that is the point of `--color-on-brand`.
  # Images, SVGs and GitHub's own label colours are content, not theme.
  def pale_fills
    page.evaluate_script(<<~JS)
      (() => {
        const out = [];
        for (const el of document.querySelectorAll('body *')) {
          if (el.closest('.label-pill, img, svg')) continue;
          const m = getComputedStyle(el).backgroundColor
            .match(/^rgba?\\((\\d+), (\\d+), (\\d+)(?:, ([\\d.]+))?\\)$/);
          if (!m) continue;
          const [r, g, b] = [+m[1], +m[2], +m[3]];
          if (m[4] !== undefined && +m[4] < 0.2) continue;
          if (Math.max(r, g, b) - Math.min(r, g, b) > 28) continue;
          if ((0.2126 * r + 0.7152 * g + 0.0722 * b) / 255 <= 0.5) continue;
          out.push(el.tagName.toLowerCase() + '.' +
                   String(el.className || '').slice(0, 60) + ' → ' + getComputedStyle(el).backgroundColor);
        }
        return out;
      })()
    JS
  end

  def contrast_with_dark_canvas(rgb_string)
    contrast(rgb_string, DARK_CANVAS)
  end

  def contrast(a, b)
    l1 = relative_luminance(a.scan(/\d+/).first(3).map(&:to_i))
    l2 = relative_luminance(b.scan(/\d+/).first(3).map(&:to_i))
    ((([ l1, l2 ].max) + 0.05) / (([ l1, l2 ].min) + 0.05)).round(2)
  end

  def relative_luminance(rgb)
    channels = rgb.map do |value|
      c = value / 255.0
      c <= 0.03928 ? c / 12.92 : (((c + 0.055) / 1.055)**2.4)
    end
    (0.2126 * channels[0]) + (0.7152 * channels[1]) + (0.0722 * channels[2])
  end
end
