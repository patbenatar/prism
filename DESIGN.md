# Prism — Design System

The reference for building Prism's screens. Feature agents: **build from this
file and reuse the shared partials and component classes below.** Don't invent
new colors, fonts or one-off spacing — if something is missing, add it to
`app/assets/tailwind/application.css` and document it here rather than reaching
for raw `slate-500` / `violet-600` utilities.

Workstream D (the rendered file view) and E (commenting) inherit §7 and §8 in
full: the gutter, block, thread and composer styles already exist, so those
workstreams write behavior and markup, not CSS.

---

## 1. Brand and tone

**Prism** is a code-review layer on GitHub for people reading documents that an
agent probably wrote. The person opening it is about to read carefully and
respond precisely. Everything serves one feeling: **precise, calm, editorial.**

The metaphor is in the name. A prism takes one beam and separates it into a
spectrum; Prism takes a pull request and separates it into something readable,
with the changes showing as colored bands down the left edge of the page. That
metaphor is not decoration — it is the color system (§2) and the one piece of
ornament the app allows itself (the spectrum seam under the top bar).

- **Not a dashboard.** No metric tiles, no sparklines, no grid of cards. The
  hierarchy is a document and its margin.
- **Not neon.** The futurism is in the letterforms and the spectrum, at low
  saturation on paper. Nothing glows.
- **Not GitHub.** Prism renders what GitHub can't. It should feel like a
  reading tool that happens to write to GitHub, not a GitHub skin.
- **Desktop-first.** Code review happens on a laptop. Layouts are built for
  1280–1600px and must still work at 390px with no horizontal scroll.

**Voice:** sentence case, plain verbs, no filler. Buttons name what happens
("Submit review", "Add single comment"). Empty states say what to do next.
Errors say what happened and when it will work again, and never apologize.
Prism explains its own limits rather than hiding them — "this block isn't part
of the diff" is a sentence we write, not a disabled button.

---

## 2. Color

Defined as `@theme` tokens in `app/assets/tailwind/application.css`, so each has
a matching Tailwind utility (`bg-brand`, `text-ink`, `border-line`, …). **Use
the tokens, never hex.**

Every colour token is a **`light-dark()` pair**, resolved from the
`color-scheme` on `:root`. There is one palette with two values per token, not
two palettes — see "Light and dark" below.

**Before you add a token, check nothing already relies on its absence.** A
declaration in `@theme` always beats a `var(--token, fallback)` somewhere
else, so adding one silently overrides every fallback anyone chose — and a
fallback is often a decision, not a guess. `--filebar-height` (§4) is the
worked example: it is measured at runtime and its fallback deliberately
under-shoots, so declaring it here would have quietly replaced a considered
value with a wrong one, in a file nobody editing the theme would think to
open. Not every value wants to be a token.

### Surfaces and ink

| Token | Light | Dark | Utility | Role |
| --- | --- | --- | --- | --- |
| `--color-canvas` | `#F2F3F8` | `#0E1020` | `bg-canvas` | The page. Cool paper with a faint violet cast; on dark, the same cast at the bottom of the scale. |
| `--color-surface` | `#FFFFFF` | `#171A2C` | `bg-surface` | Panels, rows, the top bar. The raised surface, which is why panels need no shadow in either mode. |
| `--color-sunk` | `#ECEEF5` | `#212539` | `bg-sunk` | Wells: code blocks, inset strips, hover fills. **Darker than `surface` on light, lighter than it on dark** — see below. |
| `--color-ink` | `#16182B` | `#E6E9F4` | `text-ink` | Primary text. Deep indigo, not a tinted black. |
| `--color-ink-soft` | `#565C78` | `#A2A8C4` | `text-ink-soft` | Secondary text, descriptions, metadata. |
| `--color-ink-faint` | `#6E7490` | `#858CA9` | `text-ink-faint` | Tertiary: timestamps, counts, captions. |
| `--color-line` | `#DEE1EC` | `#2B3049` | `border-line` | Every hairline. |
| `--color-line-strong` | `#C3C8DB` | `#3F4664` | `border-line-strong` | A rule that has to carry weight (table head, blockquote). |

**Dark inverts exactly one relationship: `sunk`.** On paper a well is darker
than the panel it sits in. On the dark canvas a well and a hover fill both
read as a *lift* — a hover that darkens reads as pressed or disabled — so
`sunk` sits above `surface` there. No component has to know: `bg-sunk` and
`hover:bg-sunk` stay the right answer in both modes.

### The spectrum

The review palette is ordered violet → blue → green → amber → red, and each
band has exactly one job. Nothing else may use these colors.

| Token | Light | Dark | Meaning |
| --- | --- | --- | --- |
| `--color-brand` | `#4B33CE` | `#9A89F7` | Prism itself: links, primary buttons, focus ring, the brand mark, and a **merged** pull request. |
| `--color-brand-deep` | `#37209F` | `#B7ABFF` | Hover and pressed states on brand surfaces. Darker than `brand` on light, **brighter** on dark. |
| `--color-brand-soft` | `#ECE9FD` | `#231E4A` | Tinted fill: brand pills, active and hovered rows. |
| `--color-pending` | `#1F66C9` | `#5CABF2` | An unsubmitted review — your light, not yet emitted. The tray, pending comments, `> [!NOTE]`. |
| `--color-pending-soft` | `#E1EDFB` | `#102A49` | |
| `--color-added` | `#15795D` | `#45C79A` | Added content, additions counts, an **open** PR, an approval, `> [!TIP]`. |
| `--color-added-soft` | `#DCF1E9` | `#0C2C22` | |
| `--color-modified` | `#8F5E0E` | `#D7A256` | Changed content, outdated comments, degraded-data banners, `> [!WARNING]`. |
| `--color-modified-soft` | `#FAEDD6` | `#2F2209` | |
| `--color-removed` | `#B02D3C` | `#EC8092` | Deleted content, a **closed** PR, changes requested, destructive actions, `> [!CAUTION]`. |
| `--color-removed-soft` | `#FBE3E6` | `#34141C` | |
| `--color-resolved` | `#565C78` | `#A5AAC2` | A resolved thread goes quiet. Effectively `ink-soft`, on purpose. |
| `--color-resolved-soft` | `#ECEEF5` | `#212539` | |

The dark spectrum is not the light one lightened. Pale colours crowd together
— everything ends up somewhere between L\* 62 and 76 — so each band was pushed
back apart in hue until the closest pair (`pending` against `resolved`) is
ΔE76 ≈ 31, which is where two colours stop being read as shades of each other.
The ordering violet → blue → green → amber → red survives, so the spectrum
still means what §1 says it means.

### Ink on a coloured fill

Three tokens for text that sits on a fill rather than on the page.

| Token | Light | Dark | Role |
| --- | --- | --- | --- |
| `--color-on-light` | `#16182B` | `#16182B` | Ink for a pale fill. Not a pair. |
| `--color-on-dark` | `#FFFFFF` | `#FFFFFF` | Ink for a deep fill. Not a pair. |
| `--color-on-brand` | `#FFFFFF` | `#16182B` | Text on a **solid** `brand` fill — `.btn-primary`, the hovered gutter "+". |

The first two are deliberately theme-independent, because what sits underneath
them is not ours to theme: `label_pill_style` picks one by measuring the
label's own luminance, and a GitHub label is drawn in the colour its
repository chose, which does not change when the page does. They are also the
two tokens defined outside `@theme` — Tailwind drops a theme variable no
utility references, and these are only ever read from Ruby.

`on-brand` *is* a pair, because `brand` is: white on the pale dark violet
would be 1.7:1. **Never put `text-white` on a solid spectrum fill** — see the
note under the dark table.

### Measured contrast

Every value passes WCAG AA for normal text on the canvas, on a panel, and on
its own soft fill — **in both modes** — with one long-standing exception:
`ink-faint` is 4.2 on the light canvas. It carries timestamps and counts, never
a sentence, and raising it would stop it reading as tertiary; dark has no such
tension and it sits at 5.7 there. Re-measure with `relative_luminance` in
`ApplicationHelper` if you change a value, and update both tables.

**Light**

| Foreground | on canvas | on surface | on its own `-soft` |
| --- | --- | --- | --- |
| `ink` | 15.8 | 17.5 | — |
| `ink-soft` | 5.9 | 6.6 | — |
| `ink-faint` | 4.2 | 4.6 | — |
| `brand` | 7.1 | 7.9 | 6.6 |
| `pending` | 5.0 | 5.5 | 4.7 |
| `added` | 4.8 | 5.4 | 4.5 |
| `modified` | 5.0 | 5.6 | 4.8 |
| `removed` | 5.8 | 6.4 | 5.2 |
| `resolved` | 5.9 | 6.6 | 5.7 |

**Dark**

| Foreground | on canvas | on surface | on its own `-soft` |
| --- | --- | --- | --- |
| `ink` | 15.6 | 14.2 | — |
| `ink-soft` | 8.0 | 7.3 | — |
| `ink-faint` | 5.7 | 5.2 | — |
| `brand` | 6.6 | 6.0 | 5.4 |
| `pending` | 7.7 | 7.0 | 5.9 |
| `added` | 8.9 | 8.1 | 7.1 |
| `modified` | 8.3 | 7.5 | 6.8 |
| `removed` | 7.2 | 6.6 | 6.4 |
| `resolved` | 8.2 | 7.5 | 6.6 |

Neither table covers `sunk`, the well behind code blocks and inset strips;
those ratios are recorded beside the Rouge theme at the foot of
`application.css`, because that is the only place a spectrum colour routinely
lands on it.

**Text on a solid spectrum fill flips with the mode, and there is no value
that works in both.** On light, white is legible on solid `brand` (7.9),
`brand-deep` (11.2), `added` (5.4), `pending` (5.5) and `removed` (6.4), and
**not** on `modified`. On dark it is legible on **none** of them (2.1–2.6) and
the dark ink is legible on all of them (`brand` 6.1, `brand-deep` 8.6, `added`
8.2, `pending` 7.1, `modified` 7.7, `removed` 6.7). So: never write
`text-white` on a coloured fill. Use `text-on-brand` for `brand`, and if you
need a solid fill in another band, add the matching `--color-on-*` pair and
measure it. Using a band as text or as a border needs none of this and is
usually the better answer anyway.

### Light and dark

Prism **mirrors the device**. `color-scheme: light dark` on `:root` is the
whole mechanism: it tells the browser the page renders both ways — so the
scrollbar, the caret and native form controls follow — and it is what resolves
every `light-dark()` pair above. There is no second copy of the palette, no
`@media` around the colours, and no JavaScript.

`data-theme` on `<html>` is the **manual override hook, not the mechanism**:
`"dark"` or `"light"` pins `color-scheme` to one side, and every token follows.
No UI sets it. A toggle, if one is ever wanted, only has to write that one
attribute.

Two things dark mode needs are not colours, so they are the only values
restated in a `prefers-color-scheme` block (and again under
`:root[data-theme="dark"]` — keep the two in step):

| Property | Light | Dark | Why |
| --- | --- | --- | --- |
| `--tint-strength` | `42%` | `45%` | How much of a block's `-soft` fill shows behind changed content (§7). A tint on a dark canvas reads as less present in peripheral vision, which is exactly where a skim finds it. Set by rendering 30/38/45/52/62 against the light page; above ~52% the dark page stops being a document and becomes a diff. |
| `--seam-alpha` | `0.55` | `0.9` | The spectrum seam under the top bar. Held back on paper so it reads as a horizon line; at the same opacity on the dark canvas it just looks muddy. |

Adding a colour means adding a pair, not a light value plus an override. If you
find yourself writing a dark-only rule for a colour, the token is wrong.

`light-dark()` needs Chrome 123 / Safari 17.5 / Firefox 120 (Baseline 2024),
and it is a hard floor rather than a graceful degradation: below it every
`var(--color-*)` is invalid at computed-value time, so backgrounds fall back to
transparent and text to the initial black. Prism already required `:has()`
(`.tray`'s page floor, `.file-threads`, the task-list rules), which puts the
floor in the same era; Safari 17.5 is the one version this pushes up.

`test/system/dark_mode_test.rb` pins the mechanism — that the canvas and ink
actually change, that `data-theme` wins in both directions, that the six bands
stay six colours and AA on the dark canvas, that every token changes, and that
no screen paints a pale neutral panel in dark mode.
`test/system/theme_screenshots_test.rb` renders every screen in both modes to
`tmp/screenshots/theme-*.png`. See `docs/testing.md` for how the media feature
is emulated in headless Chromium.

---

## 3. Typography

Three faces, three jobs, loaded from Google Fonts in the layout with
`display=swap`.

- **Space Grotesk** (`font-display`) — the interface. A grotesk with squared
  curves and wide apertures: technical without being cold, which is the
  "quietly futuristic" half of the brief. Wordmark, headings, buttons, pills,
  row titles, table content, metadata. Weights 400/500/600/700. It is also the
  `<body>` default, so plain text inherits it.
- **Source Serif 4** (`font-prose`) — the reading face. Rendered Markdown is
  the point of this app, so prose gets a serif drawn for screen reading. Used
  by `.md-prose` and by comment bodies. Weights 400/600/700 plus italic.
- **JetBrains Mono** (`font-mono`) — code, file paths, branch names, SHAs.
  Chosen for character disambiguation over personality.

The serif/grotesk pairing carries the app's central distinction: **the document
speaks in serif, the tool speaks in grotesk.** A heading inside rendered
Markdown is grotesk on purpose — it is the tool announcing a section of the
document.

### Scale

| Use | Classes |
| --- | --- |
| Sign-in headline | `font-display text-4xl font-semibold leading-[1.1] tracking-tight` |
| Screen title (`h1`) | `font-display text-2xl font-semibold tracking-tight` |
| Section heading | `.section-title` (sm, semibold, over a hairline) |
| Panel heading | `.panel-title` |
| Row title | `.row-title` (0.95rem, semibold) |
| Body / UI | `text-sm` |
| Metadata, captions | `text-xs text-ink-faint`, or `.row-meta` for a row's line |
| Rendered prose | `.md-prose` (1.0625rem / 1.7 serif) |
| Compact prose | `.md-prose .md-prose-compact` (0.95rem) for comments and PR descriptions |

Add `.tnum` to any column of numbers — counts, line numbers, PR numbers,
diffstats — so they line up. Rendered prose uses old-style figures; everything
else uses lining figures.

**Do not** use all-caps tracked labels. Sections are announced by a name in the
display face over a hairline (`.section-head`), because the rule already does
the separating.

---

## 4. Layout, spacing, radius, shadow

### The three widths

A screen picks exactly one and never adds another `max-w-*` / `mx-auto`
wrapper.

| Class | Width | Used by |
| --- | --- | --- |
| `.shell` | `76rem` + `px-6` | Browsing: repositories, pull requests, PR overview, the top bar. |
| `.reading-shell` | `60rem` + `px-4 md:px-6` | The Markdown review tab. A plain column, **not** a grid — see below. |
| `.shell-narrow` | `34rem` + `px-6` | Sign in, the friendly 404 and rate-limit pages. |

**The gutter grid belongs to each row, not to the page.** `.reading-shell` is
plain block flow; `.md-block` (a block of the document) and `.md-row` (page
furniture that still wants to line up: a removed strip, an "Outdated" heading,
the file-level comments) each declare the two-column template. So every change
bar sits in the same channel all the way down, and a row is free to be as tall
as its own content.

`.reading-shell` cannot itself be a grid: a `.md-block` is a grid, so as a grid
child it occupies one cell and consecutive blocks lay out **side by side**. A
full-width element is simply a child of `.reading-shell`; put an empty `div` in
a `.md-row`'s first cell when you only want the second column.

Below 640px the gutter collapses to `0.75rem` — the change bar survives, the
block's "+" moves to its top-left and stays visible, because there is no hover
on a touch screen. **Child affordances are dropped at that width**: a reviewer
on a phone comments on the list or the table, not on one item or one row. See
§7.

The top bar is `3.5rem` plus its 2px seam. Anything sticking beneath it offsets
by `var(--topbar-height)`, never by `3.5rem`, or it covers the seam.

The Markdown review page stacks the bars three deep: `.topbar`, then
`.filebar` for the page, then a `.filehead` for each file. Each offsets by the
sum of the ones above it, and each is a component class, so the sums are
written once. `.filehead` and `.file-section` both need
`calc(var(--topbar-height) + var(--filebar-height, 2.5rem))`; written twice in
markup, the two drift.

**`--filebar-height` is measured, not chosen, and is deliberately not declared
in `@theme`.** `file_nav_controller` reads the real bar and sets it on
`<html>`, because the bar wraps to two lines at phone width and a constant
would put every anchored jump a line off. A declaration in `@theme` always
beats a `var()` fallback, so it would quietly override the one the rule chose
— which is why there isn't one, and why this goes the opposite way from
`--tray-height` (§8), a token with no runtime measurement behind it.

The `2.5rem` fallback applies only with JavaScript off, and it **under-shoots**
the bar's measured 41px at 1440 on purpose. One pixel short tucks the heading
behind the bar — `z-20` to the heading's `z-10` — and nobody sees it. Three
pixels long leaves a sliver of scrolling document showing through the gap.
Under-shooting fails invisibly; over-shooting doesn't.

Everything inside `.md-prose` runs the full column width. There is no reading
measure, deliberately: prose used to be capped at 72ch while tables, code,
alerts and our own comment components ran full width, so one document rendered
at two widths and a paragraph visibly widened the moment a composer opened
under it. One width everywhere is worth more than an ideal line length. The
column itself (`.reading-shell`, `--measure-read`) is the only cap, so
narrowing *that* is how to shorten lines if we ever want to.

### Rhythm

- Page header `pt-6 pb-5`; sections `space-y-6`; a panel's rows carry their own
  `px-4 py-3`.
- Section heading to content: `mb-3` (built into `.section-head`).
- Never use vertical margins to separate panel rows — the hairline does it.

### Radius

Role, not habit: panels and threads `rounded-xl` (12px), buttons and inputs
`rounded-lg` (8px), inline wells and the gutter "+" `rounded-md`, pills and
people avatars `rounded-full`. Repository and organization avatars are
`rounded-md` (`.avatar-sq`) — squared for a thing, round for a person, the
same distinction GitHub makes.

### Shadow

Almost none. Panels are defined by a border on `surface` over the canvas, never
by a shadow. The only shadows in the system are on things that float above the
page: the account menu, the file switcher, the autocomplete listbox and the submit
popover, all `shadow-lg shadow-ink/5`. Adding a shadow to a card is a bug.

On the dark canvas `shadow-ink/5` becomes a faint light halo — invisible
rather than wrong, and deliberately left alone. A floating panel there is
already raised by being `surface` over `canvas`, and the hairline finishes the
job; a real dark shadow was tried side by side and made no visible difference.
There is no `--shadow-*` token, and a dark-only shadow override is not worth
the second rule.

### Link prefetching is off

Turbo 8 prefetches a link when the pointer rests on it. The layout turns that
off globally with `<meta name="turbo-prefetch" content="false">`.

Every screen in Prism costs GitHub calls to render — up to five for the
repository list, four for a pull request overview, more for the rendered file
view — and a prefetch is a full server-side render. Left on, running an eye
down a list of twenty pull requests spends twenty pages' worth of the
reviewer's GitHub rate limit on pages they never opened, against a budget
PLAN.md already treats as scarce.

Global rather than per-link on purpose: a per-link opt-out is a rule every
future link has to remember, and forgetting it fails silently. If a genuinely
cheap screen ever exists, opt that one link back in with
`data-turbo-prefetch="true"`. An integration test pins the tag, because
deleting it breaks nothing visible.

### Content Security Policy

Enforced in every environment, from `config/initializers/content_security_policy.rb`.
Prism renders HTML that came from GitHub, so the sanitizer is one layer and
this is the other: if a tag ever slips the safelist, the browser still refuses
to run it.

| Directive | Value | Why |
| --- | --- | --- |
| `default-src` | `'self'` | Everything not named below. |
| `script-src` | `'self'` + per-request nonce | No inline scripts and no `on*` attributes exist in the app. Importmap's inline tags get the nonce automatically. Never `unsafe-inline` or `unsafe-eval`. |
| `style-src` | `'self' https://fonts.googleapis.com` + nonce | The Tailwind build, the Google Fonts link, the `<style>` Turbo injects for its progress bar — Turbo reads `csp-nonce` and sets it on that element — and a mermaid diagram's own stylesheet, which `mermaid_controller.js` nonces the same way. See below. |
| `style-src-attr` | `'unsafe-inline'` | The one exception, for GitHub label colours. See below. |
| `font-src` | `'self' https://fonts.gstatic.com` | The three web faces. |
| `img-src` | `'self' https: data:` | Avatars, and an image in a rendered Markdown file can be hosted anywhere. No allowlist covers "whatever the document links to". |
| `connect-src` | `'self'` | Nothing in Prism calls GitHub from the browser; every GitHub request is server-side with the user's token, which keeps that token out of the page. |
| `form-action` | `'self' https://github.com` | The sign-in button POSTs to `/auth/github` and OmniAuth answers with a redirect to github.com. |
| `frame-ancestors` | `'none'` | Prism is never framed. |
| `object-src` | `'none'` | No plugins. |
| `base-uri` | `'self'` | No page may rewrite the base URL under a relative link. |

**Why `style-src-attr 'unsafe-inline'`.** A GitHub label is drawn in the colour
the repository chose, which only an inline `style` can express, because the
value is data rather than a class. A nonce cannot apply to an attribute, so
there is no tighter option. The exposure is bounded: the only inline style
Prism emits comes from `label_pill_style`, and the only part of it that comes
from GitHub is the hex, matched against `\A\h{6}\z` and re-emitted through
`format("#%02x%02x%02x")`, so it cannot carry anything but three numbers.
Everything around it is a fixed string we wrote — `var(--color-on-light)` or
`var(--color-on-dark)` for the text, and a `color-mix(… var(--color-ink))` for
the border, which is how a border computed in Ruby can still follow a theme
Ruby cannot see. And `style` is not in `GITHUB_HTML_ATTRIBUTES`, so the
sanitizer strips it from every piece of GitHub-authored HTML. Note that `style-src-attr` deliberately carries **no**
nonce: adding one would cancel the `unsafe-inline` the labels depend on.

**Mermaid runs under this policy unchanged.** It was the first thing that
looked like it might not. A diagram's colours arrive as a `<style>` element
mermaid builds itself, which `style-src 'self'` blocks — and mermaid has no
configuration for a nonce. `mermaid_controller.js` stamps one on at the two
points a stylesheet comes into being, for the length of one render:
`document.createElement`, and `DOMParser.parseFromString`. The second is
needed because **a nonce does not survive being written out as text**: the CSP
nonce-hiding rule empties the `nonce` content attribute once an element is in a
document, so when mermaid serializes the finished SVG and hands the string to
its own DOMPurify pass, the `<style>` inside arrives as `nonce=""` and
re-parsing it is a second violation — inside mermaid, not inside us. Putting
the nonce back into the string on the way into any parse closes both. Nothing
was added to `script-src` or `style-src`; `unsafe-inline` and `unsafe-eval`
remain absent, and the vendored bundle contains no `eval`, no `new Function`
that is ever reached, and no dynamic `import()`.

The library itself is an ordinary `'self'` script: it is vendored under
`vendor/javascript/` and loaded from `/assets`, never a CDN.

**`style-src-attr` is still only the label pills.** The SVG a diagram produces
is walked against an allowlist before it reaches the page and every `style`
attribute in it is dropped — the diagram's own `classDef` and `style`
directives live in its stylesheet, not in attributes, so nothing is lost. The
drawing's size is set from its `viewBox` as plain `width`/`height` attributes.
One fallback path, for a diagram type that somehow produces no `viewBox`, sets
`max-width` through CSSOM from a number matched against `[\d.]+` — CSSOM is not
an inline style attribute as far as CSP is concerned, and the value cannot
carry anything but digits.

**The nonce is random per request**, not derived from the session id as Rails
suggests. A signed-out visitor has no session id, which would render `nonce-`
and block every script on the sign-in page — the one page a new user sees.
Prism caches no pages, so the cacheability the session-id nonce buys is worth
nothing here.

**Adding an origin.** Add it to the narrowest directive, then run
`bin/rails test:system`. `ApplicationSystemTestCase#assert_no_csp_violations`
reads the browser console, which is the only place a violation is reported —
the page still renders and the blocked thing simply never runs, so a CSP
mistake otherwise looks like a passing test.

**One directive is not covered by a test.** `form-action https://github.com`
cannot be exercised: OmniAuth's test mode short-circuits the request phase and
redirects straight to our callback, so no suite reaches the real hop to
github.com. Verify it by hand against a real OAuth app.

### Density

This is a desktop reading tool, so rows are `py-3` rather than a 44px touch
target. Anything that must also work under a thumb — the gutter "+", the
account menu, buttons — is at least 24px and sits in a larger padded hit area.

---

## 5. Component inventory

### Component classes (`app/assets/tailwind/application.css`)

Four bases are registered with `@utility` (`btn`, `pill`, `field-input`,
`flash`) because Tailwind 4 only lets `@apply` reference real utilities. If you
add a class that others will build on, do the same.

**You never write `cursor-pointer`.** Preflight resets `<button>` to the
default arrow, which left the gutter "+", a reaction, "Submit review" and a
`<summary>` used as a menu all reading as text while every plain link read as
a control. `@layer base` now gives `button:not(:disabled)`, `summary`,
`[role="button"]`, checkboxes, radios, submit/reset inputs and `select` a
pointer, and `.btn` and `.tab` carry it too. Stated once there so a new button
never has to remember it; disabled buttons still get `not-allowed` from
`.btn`. If something clickable still shows an arrow, the base rule has a gap —
fix it there, not on the component.

| Class | What / when |
| --- | --- |
| `.shell` / `.shell-narrow` / `.reading-shell` | The three content widths (§4). |
| `.topbar` / `.topbar-inner` / `.topbar-seam` | Sticky top bar and its spectrum rule. Rendered by the layout. |
| `.panel` / `.panel-head` / `.panel-title` | The bordered container every list lives in. |
| `.row` | A static row inside a panel. |
| `.row-link` | A row that navigates: hover fill plus a brand tick on the left edge. |
| `.row-title` / `.row-meta` | A row's headline and its metadata line. |
| `.section-head` / `.section-title` / `.section-note` | A section's name over a hairline, with an optional right-hand note. |
| `.btn` + `.btn-primary` / `.btn-secondary` / `.btn-ghost` / `.btn-danger` | Buttons. `.btn-lg` and `.btn-sm` adjust size. One primary per screen. `.btn-primary`'s text is `on-brand`, never `white` (§2). |
| `.field-label` / `.field-input` / `.field-search` / `.field-hint` | Forms. `.field-search` adds room for a leading icon. |
| `.pill` + `.pill-neutral` / `-brand` / `-pending` / `-added` / `-modified` / `-removed` / `-resolved` | Every status pill. `.pill-solid` is the heavier variant for a PR header. |
| `.label-pill` | A GitHub label. Colors come from `label_pill_style(hex)`. |
| `.mono-tag` | Branch names, paths, SHAs — anything retypable. |
| `.avatar` / `.avatar-sq` | Round for people, squared for repositories and orgs. |
| `.tabs` / `.tab` / `.tab-active` | Underline tabs. A component built on `.tab` must write its active state as two classes (`.composer-tab.tab-active`), or `.tab`'s own `border-transparent` ties with it on specificity and the compiler's ordering decides which underline you get — the same trap §7 documents for the gutter. |
| `.filebar` / `.filebar-inner` / `.filehead` / `.file-section` | The Markdown review page's pinned bars and its per-file section. See §7. |
| `.flash` + `.flash-notice` / `.flash-alert` | Flash messages, rendered by the layout. |
| `.banner` | A degraded-data notice above content that still rendered. |
| `.empty-state` / `.empty-title` / `.empty-body` | Empty states. |
| `.tnum` | Tabular figures. |

Review-screen classes are in §7 and §8.

### Shared partials (`app/views/shared/`)

| Partial | Purpose / locals |
| --- | --- |
| `_top_bar` | The app shell's bar. **Rendered by the layout** for signed-in screens — don't render it. Add context with `content_for :breadcrumb` and actions with `content_for :top_bar_actions`. |
| `_account_menu` | Avatar → GitHub profile (`User#html_url`), sign out. A native `<details>`; the `menu` controller only adds outside-click and Escape closing. |
| `_prism_mark` | The brand mark. Locals: `size:` (px, default 24), `tile:` (dark rounded tile, default false), `class:`. Keep in sync with `public/icon.svg`. |
| `_flash` | Notice and alert. **Rendered by the layout** — don't re-render. |
| `_page_header` | A browsing screen's title block. Locals: `title:` (required, string or `capture`d HTML), `subtitle:`, `meta:`, `actions:`.  **Passing two or more `actions:` collapses the title at phone width** — the slot is `shrink-0` beside a `flex-1 min-w-0` title, so the title is what gives. Wrap multiple actions in a div with a phone-width floor; `pull_requests/index` shows the shape. |
| `_empty_state` | Locals: `title:` (required), `body:`, `icon:` `:prism`/`:repo`/`:pull`/`:file`/`:search`, `cta_label:` + `cta_to:`. |
| `_labels` | GitHub labels in the repo's colors. Locals: `labels:` (array of `Github::Types::Label`), `limit:` (then "+N more"). |
| `_rate_limit_banner` | Locals: `retry_in:` (seconds, from `Github::RateLimited#retry_in`) and `reset_at:` as a fallback. Use above content that rendered anyway. |
| `_comment_card` | One review comment: avatar, login, time, pending/outdated pills, prose body, reaction pills. Locals: `comment:` (required), `actions:` (safe HTML for the action row). **This is the reference for all comment styling** — extend it with `actions:`, don't restyle it. |
| `not_found` / `forbidden` / `rate_limited` | Full-page error screens rendered by `GithubErrorHandling`. |
| `webhook_subscriptions/_watch` | The Watch / Stop watching control, in the repository page's header. Locals: `owner:`, `name:`, `subscription:` (may be nil). Posts to the existing subscription actions with `from: "repo"`, so there is no second copy of the GitHub logic and no extra route. |
| `webhook_subscriptions/_watch_menu` | The watching half of the control: a `<details>` whose `<summary>` *is* the state (`✓ Watching`, `Not working`, `Wrong address`). Stopping lives one click inside, quiet at rest. State is carried as a word, never colour alone. |
| `webhook_subscriptions/_consent` | What watching does, in one place. Rendered by the "What happens?" disclosure *and* by `/subscriptions`, so the two screens cannot drift into saying different things about an action that edits other people's pull requests. Change the wording here only. |
| `webhook_subscriptions/_status_pill` / `_status_reason` | Active / Not working / Wrong address, and the sentence explaining each. Shared by both screens for the same reason. |

### Helpers

`ApplicationHelper`:

- `relative_time(time, prefix: nil)` — a `<time>` reading "3 days ago" with the
  exact timestamp in its `title`. Pass `prefix: "opened"` for "opened 3 days
  ago".
- `duration_in_words(seconds)` — "10 minutes", for a rate-limit wait.
  `Github::RateLimited#retry_in` gives the wait directly, which beats deriving
  it from a timestamp when GitHub sent a `retry-after` header.
- `relative_time_until(time)` — "in about 12 minutes", the fallback when only
  the reset timestamp is known.
- `label_pill_style(hex)` — inline style for `.label-pill`: computes a text
  color that passes contrast against whatever hex the repo chose, plus a
  darkened border so a pale label doesn't dissolve into a white panel.
- `diffstat(additions, deletions)` — "+128 −7", colored.
- `count_of(n, singular, plural = nil)` — "3 files".
- `github_html(html)` — sanitizes HTML that came from GitHub on its way into a
  view. Uses `Markdown::Sanitizer` when workstream B's is loaded and a Rails
  HTML5 safelist until then. **Every** GitHub-sourced HTML goes through this.
- `github_profile_url(login)`, `reaction_emoji(content)`.

`PullRequestsHelper`:

- `pull_request_state(pr)` → `[:merged, "Merged", "pill-brand"]`. Draft outranks
  open; merged outranks closed.
- `review_decision(reviews)` → `[:approved, "Approved", "pill-added"]`, derived
  from the review list the way GitHub derives it (latest submitted review per
  author, comment-only reviews don't decide).
- `review_state_label(state)`, `file_status_label(status)` — word plus pill
  class.
- `split_path(path)` → `["docs/guides/", "setup.md"]`, so a row can mute the
  directory and weight the filename.
- `pull_request_tabs(current_state)`.

Every one of these returns a **word** as well as a color. Nothing in Prism is
conveyed by color alone.

### Stimulus (`app/javascript/controllers/`)

- `menu_controller` — closes a `<details>` menu on outside click or Escape.
- `filter_controller` — filters an already-rendered list as you type. Targets:
  `query`, `item` (each carrying `data-filter-text`), `empty`, `count`,
  `hideWhenFiltering`.
- `mermaid_controller` — draws a ```mermaid fence as a diagram beside its
  `<pre>`. Attached by `PullRequestFilesHelper#wrap_mermaid`, so it exists only
  on a page that has one. Targets: `source` (the `<pre>`), `figure`, `error`,
  `toggle`. See §9.

---

## 6. Per-screen notes

Every screen sets `content_for :title`. Signed-in screens get the top bar from
the layout and should set `content_for :breadcrumb`.

1. **Sign in (`/sign_in`)** — the only signed-out screen, so no top bar. Two
   columns at `lg`: the headline, the promise, the `button_to` (OmniAuth
   requires a POST, so never a link), and a sentence on the `repo` scope; then
   a **miniature of the review screen** built from the real `.md-block` and
   `.thread` classes. It is the hero because it shows what the product does,
   and it stays honest because it is not a picture. It collapses under the copy
   on a phone and is `aria-hidden`. Because it is built from the real classes,
   it is also the fastest place to see a theme change: the change bars, the
   block tint, a thread and the gutter "+" are all on the one signed-out
   screen.
2. **Repositories (`/repos`)** — `.shell`. A search box filtering the rendered
   list client-side (`filter` controller); GitHub returns one page of 100
   sorted by most recent push, which is small enough to search with no round
   trip and keeps working while we are rate-limited. "Load more" raises `?page=`
   and the controller re-fetches pages 1..n so the list grows rather than jumps
   (capped at 5 pages). Rows are one ledger panel: owner avatar (squared for an
   org), `owner/name` with the owner muted, a Private pill, the description
   clamped to two lines, then open-issue count and "pushed 2h ago".
3. **Pull requests (`/:owner/:repo/pulls`)** — `.shell`. Underline tabs for
   Open / Closed / All. Rows carry a state pill, the title, up to four labels,
   then `#number`, "opened 3 days ago by author", files changed, and "updated".
   **Deviation from PLAN.md:** the screen map asks for a review-decision pill
   and an "N Markdown files" pill here. Neither is available from the list
   endpoint — the decision needs GraphQL and the Markdown count needs the files
   endpoint per pull request, which is far too expensive for a list. Both
   appear on the overview instead, and the list shows `changed_files`.
4. **PR overview (`/:owner/:repo/pulls/:n`)** — `.shell`, then a
   `minmax(0,1fr) 18rem` grid. Header: state pill, review decision, title with
   number, author, opened/updated, `base ← head` as mono tags, labels, "Open on
   GitHub". Main column: the description rendered through GitHub's `/markdown`
   and sanitized, then **Markdown files** (the point of the app — these link to
   `repo_pull_file_path` and show status, rename source, diffstat, and a warning
   when GitHub sent no patch), then **Other files**, muted, linking out to
   GitHub. Side column: reviews by author, a pending-review note, and a small
   changes summary.
5. **Pull request tabs and the Markdown tab** — two tabs on both pull request
   screens, **Overview** (`/:owner/:repo/pulls/:n`) and **Markdown**
   (`/:owner/:repo/pulls/:n/markdown`), each carrying the one count that is
   free to it: changed files, and renderable `.md` files. A comment count is
   deliberately absent — it lives only in the `reviewThreads` GraphQL query,
   which the overview does not make. The Markdown tab renders **every**
   renderable `.md` file in the pull request on one page, in the file list's
   order, built from `.reading-shell`, §7 and §8. Each file is a `<section>`
   under a sticky heading (status pill, path, diffstat, link out) that pins
   under the review bar, which pins under the top bar (§4). The file switcher
   stays top-left but is a jump menu: its rows are fragment links, they scroll
   rather than navigate, and they carry `data-turbo="false"` so Turbo does not
   treat a same-page anchor as a visit and re-render the body from its
   snapshot cache — which would throw away an open composer. Per-file
   previous/next is gone; `n`/`p` walks the changed blocks of the whole pull
   request, across file boundaries. File-level comments sit at the top of
   their own file's section and the outdated section at the end of it, not
   once at the foot of the page. The pending-review tray is still one per
   page.
6. **Error screens** — `GithubErrorHandling` turns `Github::NotFound` into a
   friendly 404 that says GitHub answers the same way for a missing and a
   private repository, `Github::Forbidden` into an org-approval explanation, and
   `Github::RateLimited` into a page that says when the limit resets. Use
   `_rate_limit_banner` instead when the page rendered anyway with stale data.

---

## 7. Review gutter

The primitives the Markdown review tab is built from. Workstream D writes the
behavior; these styles already exist and should not be re-cut.

```erb
<div class="md-block md-block--added" data-block-id="…">
  <div class="md-gutter">
    <span class="md-gutter-bar"></span>
    <button class="md-add">+</button>
  </div>
  <div class="md-body md-prose">…sanitized block HTML…</div>
</div>
```

| Class | What it does |
| --- | --- |
| `.md-block` | The per-block grid. Same template as `.reading-shell`, so gutters align. |
| `.md-block--added` / `--modified` / `--removed` | Sets the change bar's color, and tints `.md-body` very faintly for added and modified. The tint is `--tint-strength` of the soft fill (42% light, 45% dark — §2) — a skim should find the changes without the page becoming a diff. |
| `.md-gutter` | The gutter cell. |
| `.md-gutter-bar` | The 3px change bar, full block height. Transparent when unchanged, so an unchanged page is just the document. |
| `.md-body` | The block's content cell. |
| `.md-add` | The "+" affordance. `opacity-0` until `.md-block:hover` or `:focus-within`, and always reachable by keyboard because it is a real focusable button. |
| `.md-add--muted` | For a block GitHub can't anchor a line comment to. Dashed border, muted color. **It still works** — it opens the composer in file-comment mode. The difference must be visible before the click, and the reason must be stated in words in the composer. |
| `.filebar` / `.filebar-inner` | The page's bar under the app top bar: file switcher, jump menu, change count. Sticks at `var(--topbar-height)`. `.filebar-inner` is capped at `--measure-read` so it lines up with the document. |
| `.filehead` | One file's heading: status pill, path, diffstat, link out. The third bar in the stack — sticks under `.filebar`, `z-10` to its `z-20`, so a file's heading scrolls up and under the page's own bar. Full-bleed through `.reading-shell`'s padding. It owns its flex layout; don't re-cut it in the view, and never set its offset with an inline `style` (§4). |
| `.file-section` | One file's whole section. Carries the `scroll-margin-top` that clears both bars above it, so the jump menu, a deep link and the per-file route's redirect all land in the same place. |
| `.md-row` | The two-column template for page furniture that is not a block. |
| `.md-child` + `.md-add--child` | A list item a reviewer can comment on alone. The block-level hover is **cancelled** for children and re-granted only to the child under the pointer, so hovering a list does not light up every item at once. Inside a nested list the "+" moves into that list's own indent channel, at any depth. |
| `.md-child-table` + `.md-add--row` | A table row's "+". A table is `overflow-x-auto`, so the button cannot hang outside it — the first cell gets `pl-9` and the button sits inside. |
| `.md-thread-row` | The extra `<tr>` carrying a table row's threads and composer. Drops the rule above it, so it reads as a continuation of its row. |
| `.md-removed-strip` / `.md-removed-summary` / `.md-removed-body` | The collapsed strip for content this PR deleted, shown where it used to be. Expanded content is struck through and at 75% opacity. |

Rules for workstream D:

- Never convey "commentable" with color alone; the muted "+" is paired with an
  explanation in the composer.
- An unchanged block gets no tint and no bar. Restraint here is what makes the
  changed blocks legible.
- The gutter is `2.5rem` on desktop and `0.75rem` below 640px. At phone width
  the "+" cannot live in the gutter, so it moves to the block's top-left and
  stays visible.
- **Below 640px there are no child affordances.** A reviewer comments on the
  list or the table, not on one item or one row. This is a product decision,
  not a layout workaround: there is nowhere for a second nested affordance to
  go at that width, and every candidate position covers the "1." and "2." of
  an ordered list — numbers that carry meaning in a document under review.
  Nothing becomes uncommentable, because the block's own "+" still covers the
  whole list or table. The room the row button needs in a table's first cell
  is reserved only above 640px, so the narrowest column doesn't pay for a
  button that isn't there.
- **Every id on the page is prefixed with its file's key**
  (`Review::Page.file_key(path)`, ten hex characters of SHA-256 over the
  path). `Markdown::Renderer` numbers blocks from zero *per document*, so two
  files whose first block is the same heading produce the same block id.
  Without the prefix that is duplicate `block_`, `threads_` and `composer_`
  containers, one gutter serving two blocks, and a comment appended under the
  wrong file.
- **Two cascade traps, both already handled — don't undo them.** The phone
  rule for the block's "+" carries `:not(.md-add--child):not(.md-add--row)`,
  because it is two classes and the child rules are one, so without the
  exclusions it collapses every child button onto the left edge of its own
  `<li>`. And the compiler reorders rules, so an override of equal specificity
  is not guaranteed to win — scope a rule to the width where it applies rather
  than setting it always and overriding it.

---

## 8. The commenting family: composer, thread, comment card, tray

The composer and the comment card are **one component family**. A thread with
its reply box open *is* the composer's next state, so both are built from the
same frame (`.composer-card`), and a comment is the same card once it has been
said. Three rules hold the family together:

1. **Nothing is announced by a fill.** A thread stays on the base surface in
   every state. What changes is a 3px band down its left edge, in the spectrum
   colour of that state — the same language the gutter's change bar speaks two
   columns to the left — plus the word in its badge. The tinted panels this
   replaced (a blue wash for a draft, grey for resolved, a sunk strip under a
   composer) read as a different kind of object sitting on the document rather
   than a part of it.
2. **No rule above a thing, only between things.** The composer no longer hangs
   under a hairline; its own border is its edge. Inside a thread the hairlines
   separate one comment from the next and nothing else.
3. **Destructive is quiet until you reach for it.** Edit and delete are
   equal-weight icon buttons in the card's top right; delete takes the removed
   colour on hover and focus only. A red button beside a ghost one made
   deleting look like the expected move.

| Class | What / when |
| --- | --- |
| `.thread` | Wraps a stack of comment cards and the reply box. Always `bg-surface`. Modifiers add the left band: `.thread--pending` (an unsubmitted draft), `.thread--outdated` (amber), `.thread--resolved` (grey, and collapsed behind a `<details>`). Written as `.thread.thread--pending` so the override beats `border-line` whatever order the compiler emits. |
| `.thread-head` | Badges (Outdated, On removed content, Resolved) and the resolve toggle, `ml-auto`. **Rendered only when it has something to carry** — an ordinary thread opens straight onto its first comment, with no strip above it. |
| `.thread-comments` | The comments container (`#thread_comments_<node_id>`). Draws the hairline *between* comments: each comment renders inside its own `#comment_<node_id>` wrapper, so `:last-child` on the card can never see its siblings. |
| `.thread-foot` | The room the reply box sits in. No rule above it — the composer card's own border already separates it from the conversation. |
| `.comment-card` | One comment: head, body, actions. No border of its own. |
| `.comment-head` / `.comment-author` | Avatar, login, relative time, pending/outdated pills, then `.comment-tools`. Wraps at phone width. |
| `.comment-tools` / `.comment-icon` / `.comment-icon--danger` | The icon row in the top right: edit, delete, open on GitHub. 28px hit area, 16px stroke icon, `text-ink-faint` until hover. `--danger` only reddens on hover and focus. `button_to` wraps its button in a form, so `.comment-tools form` is `display: contents`. Every icon carries an `sr-only` name. |
| `.comment-body` | The body. Always `md-prose md-prose-compact`. |
| `.comment-actions` | The quietest row on the card: reaction counts, then the add-reaction trigger. |
| `.reaction-pill` / `.reaction-pill--on` | A reaction, 24px tall. The summary under a comment is a `<span>` — a count, not a control — so only `button.reaction-pill` (the picker's own) gets `cursor-pointer` and a hover state. `--on` is filled in brand, so the toggle reads without counting. |
| `.reaction-add` / `.reaction-menu` | The add-reaction trigger and its popover. The trigger is a bare 24px icon on the surface, not a bordered box: reacting is an invitation, not a control with standing. |
| `.composer-card` | The composer, the reply box and the edit form: tabs, textarea and buttons in one frame. `:focus-within` puts the brand ring around the **whole card**, because the card is the input. |
| `.composer-card--compact` | The reply box at rest: one line saying "Reply…", with the tabs and the buttons folded away until focus lands inside. `:focus-within` is the whole mechanism — no JavaScript, works from the keyboard, cannot get stuck open. A page can hold a dozen threads, and a full editor under each one is a wall of chrome around a document nobody has replied to yet. |
| `.composer-head` / `.composer-tab` | The Write/Preview pair. Real `role="tab"` buttons in a `role="tablist"`; `markdown_preview_controller` keeps `tab-active` and `aria-selected` in step. No `aria-controls`: several composers can be open on one page, so a panel id could not be unique. |
| `.composer-note` / `--warn` / `--error` / `--inline` | What the composer says instead of making you find out: why a block can't be anchored (`--warn`), what a file-level comment will do, the error from the last attempt (`--error`, `role="alert"`). `--inline` drops the block padding so a note can stand in a button's place inside `.composer-foot` — see the review-only rule below. |
| `.composer-foot` | The button row. `flex-wrap`, so Cancel / Add single comment / Start a review stack instead of overflowing at 390px. |
| `.composer-textarea` | The textarea — serif, because you are writing prose about prose. Standalone it is a bordered `field-input` (the tray's review summary); inside `.composer-card` it gives up its own frame and the card carries it. |
| `.tray` / `.tray-inner` | The pending-review bar. **Fixed**, not sticky — see below. `.tray-inner` is capped at `--measure-read` so it lines up with the document above it. Render it into `content_for :tray`, which the layout yields after `<main>`. |

**A thread is not prose, and neither is a comment's chrome.** A thread renders
inside the block's body, which carries `.md-prose`, so §9's descendant rules
(`a`, `img`, `details`, `summary`) reach this markup too and dress a control as
though it were part of the document: the reaction picker came out in a bordered
box, the "On GitHub" icon brand-coloured and underlined, the timestamps in the
reading serif. A short "not prose" block at the end of the section puts the
chrome back, with **two classes per selector** — `.md-prose details` is one
class and one element, and a selector with more classes wins however the
compiler orders them. The comment *body* is deliberately left alone: the
Markdown inside it really is prose. If you add a control to a comment, check it
against a `.md-prose` rule of the same name before you trust it.

**The composer says nothing about line numbers.** The reviewer picked the block
by clicking it; the anchor is plumbing that still goes to GitHub in hidden
fields. `anchorNote` survives for the one thing worth saying — *why* a block
cannot be anchored at all — and is hidden when there is nothing to say.
`composer_controller.js` fills it on open; `_composer_form` fills it from
`uncommentable_reason` on the error re-render, where no JS runs.

**While a review is open, the standalone actions are gone, not disabled.**
GitHub refuses both of them: `addPullRequestReviewThread` with a
`pullRequestId` — the "Add single comment" path — silently attaches the
comment to the open review and answers with it in state `PENDING`, and an
immediate REST reply fails 422 with *"user_id can only have one pending review
per pull request"*, because a standalone reply implicitly opens a second
review. So "Add single comment" and "Reply" are **absent** while one is open,
with a `.composer-note--inline` where each of them was ("Your review is in
progress, so this joins it"). A disabled control invites the reviewer to
wonder what they did wrong; an absent one with a sentence explains itself.

Both the buttons and the notes stay in the DOM with `hidden` toggled, never
rendered conditionally, because the state changes mid-session: starting a
review from one composer has to flip every reply box already on the page and
the `<template>` the next composer is cloned from. `composer_controller`'s
`applyReviewOnly` does that from the existing `pending-review:changed` event
— the same one that already swaps the review button's label — and runs again
over each fresh clone. Cmd+Enter follows the same rule: it submits the review
button when the single one is hidden, or it would post exactly the comment the
UI has stopped offering.

A page can still go stale — a review opened in another tab — and ask for a
single comment anyway, and the client cannot know. `ReviewCommentsController`
catches that on the way back instead: the mutation returns the comment, and if
a request that asked for `single` gets one in state `PENDING`, GitHub joined it
to a review we did not know about. That write streams a notice into `#flash`
("Your review was already in progress, so this joined it") and re-reads the
tray rather than deriving it from the hidden fields, which were wrong too. It
is the only write that re-reads, and only in that branch. `#flash` is a stable
wrapper in the layout for exactly this — `shared/_flash` renders nothing when
there is no flash, so it has no id of its own to aim at.

**The composer's error path is an `update`, not a `replace`.**
`composer_<block_id>` is the file view's own empty slot and `_composer_form`'s
root carries no id of its own, so replacing the slot would leave the composer
unreachable by `getElementById` for the rest of the page's life. Keep the root
id-less.

**The tray is `fixed`, and the page carries a floor to match.** Sticky pins an
element only while its containing block is on screen, and the tray is the last
child of `<body>`, so sticky pinned it exactly at the bottom of the page — the
one place a reviewer does not need it. It is now `fixed inset-x-0 bottom-0`,
with `body:has(.tray) main { padding-bottom: var(--tray-height) }` keeping the
end of the document out from under it. Discard is a ghost button that only
reddens on hover, for the same reason a comment's delete icon is.

`--tray-height` is **measured, not chosen**: 59px at laptop width, 61px at
390px, set to 4.5rem with headroom. It only holds because `.btn` is
`whitespace-nowrap` — while "Submit review" wrapped to two lines the bar grew
to 77px at phone width and a 4.25rem floor hid the last 9px of the document.
`test/system/tray_layout_test.rb` measures the real bar at both widths and
fails with both numbers in the message if either drifts. Don't set it by eye,
and don't let a button label wrap.

`html:has(.tray)` also carries `scroll-padding-bottom`, so anything the browser
scrolls to — a composer textarea taking focus near the bottom — stops clear of
the bar. Only the bottom: `block_nav_controller` already offsets the top by
measuring the pinned bars, and setting both would double it.

**Threads and composers are not prose.** `.md-prose > *` caps every direct
child at the reading measure, and a thread or composer rendered inside
`.md-body` is a direct child — which left the comment box at 72ch inside an
848px column. `.md-threads` and `.md-composer` are in the exception list beside
`pre`/`table`/`img`, along with `ul:has(.md-composer:not(:empty))` and the `ol`
and `.md-threads` equivalents, so a composer opened on a list item gets the
same room. The prose beside them is still capped; the layout test asserts both
halves, because widening everything would be just as wrong.

A file's file-level comment section stays in the DOM while it is empty, so a
comment streamed in by Turbo always finds a heading waiting for it, and hides
itself with `[&:not(:has(.file-threads-list>*))]:hidden` in
`_file_threads.html.erb`. That rule used to live in the stylesheet keyed off a
page-wide `#file_threads` id; the id stopped existing when the review screen
became one page holding every Markdown file, and the rule stayed in the
partial rather than coming back, because exactly one partial uses it.

Gate Edit / Delete / Resolve on `viewer_can_*` from the value object, never on
comparing logins — GitHub already decided, and a repo admin can delete comments
they did not write.

---

## 9. Rendered Markdown prose

`.md-prose` styles sanitized HTML we cannot add classes to, so everything is a
descendant selector. Apply it to a block's body, a PR description, or a comment
body; add `.md-prose-compact` when the prose sits inside a card rather than
being the whole page.

Covered: `h1`–`h6` (display face, `h1`/`h2` over a hairline), paragraphs,
links, `strong`/`em`/`del`, ordered and unordered lists with nested lists and
multi-paragraph items, task lists (the checkbox replaces the bullet),
blockquotes, `hr`, inline `code` and fenced `pre` (mono in a sunk well,
horizontally scrollable), tables (display face, tabular figures, scrollable
rather than wrapped), images, `<details>`/`<summary>`, footnote references and
the GFM footnotes section, and GitHub alerts.

**Alerts** take the spectrum band that matches their severity, so an alert
speaks the same language as a change bar: `.markdown-alert-note` → pending,
`-tip` → added, `-important` → brand, `-warning` → modified, `-caution` →
removed.

**Mermaid** — a ```mermaid fence is drawn as a diagram. GitHub renders one;
showing the source instead is the thing this product exists to fix.

The `<pre>` is never replaced and never moves. It carries `data-sourcepos`, it
is what the block's gutter "+" anchors a comment to, and with JavaScript off it
is still the whole block — so the diagram is a *sibling*.
`PullRequestFilesHelper#wrap_mermaid` (after sanitizing, like every other
wrapper here) puts both inside `.md-mermaid`, whose `data-mermaid-state` picks
which one is on screen: `source` is what the server renders, and the controller
flips it to `diagram` only once it has actually drawn something. A
`.md-mermaid-toggle` button appears underneath, added by the controller so it
exists only where there is something to toggle to.

- **The frame** (`.md-mermaid-figure`) is a bordered panel on `surface`, and it
  scrolls sideways rather than shrinking the drawing. A diagram too wide for
  the reading column is scrolled at a readable size, the way a wide table is —
  scaling it to fit turns a flowchart into an illegible thumbnail at 390px.
- **The theme is the page's.** `theme: "base"` with `themeVariables` read out of
  the stylesheet: nodes take `sunk` (a well on paper, a lift on the dark
  canvas, which is the one relationship dark mode flips), borders `line-strong`,
  edges `ink-faint`, labels `ink`, the display face, notes the `modified` band.
  Every token is a `light-dark()` pair, so each is painted onto a probe and read
  back as a used value — the same trick `DarkModeTest` uses. Which side won is
  decided from the resolved canvas colour, not re-derived from
  `prefers-color-scheme` and `data-theme`, so the stylesheet stays the one
  source of truth. A scheme change while the page is open redraws every
  diagram.
- **A diagram that cannot be drawn is one bad diagram.** The block keeps its
  gutter, the source stays on screen, and `.md-mermaid-error` says so in a
  `removed`-band note with mermaid's own parse error under it in mono, newlines
  kept, because that error points at the offending column with a caret.
- **It costs nothing when there is nothing to draw.** The library is vendored
  (3.5 MB, 953 KB gzipped — the app adds no `Rack::Deflater`, so whether that
  is what crosses the wire is up to the edge in front of it) and pinned
  `preload: false`; the controller is
  attached by the server only where a fence exists, so a pull request without
  one makes no request for it. One fetch however many diagrams a page holds.
- **The SVG is untrusted.** It is built in the browser from a fence in somebody
  else's repository, which `Markdown::Sanitizer` never sees. `securityLevel:
  "strict"` (never `loose` or `antiscript`), `htmlLabels: false`, and
  `bindFunctions` is never called, so no `click` directive can attach anything.
  On top of that the controller walks the SVG against an element allowlist,
  drops every `on*` and `style` attribute, allows only `http(s)`, `mailto` and
  `#` in anything that names a resource, and namespaces every `id` to
  `user-content-` — rewriting `url(#…)`, `href="#…"` and the `#id` selectors in
  the diagram's own stylesheet to match — for the reason `Markdown::Sanitizer`
  namespaces the document's.

**Code highlighting** — one Rouge theme is defined at the end of
`application.css` against `.md-prose .highlight`. Comments recede to
`ink-faint` italic, keywords take the violet end, strings the green, numbers the
amber, class and function names the blue. `.gd` / `.gi` (diff removed/added)
use the removed and added soft fills.

There is one theme, not two: every rule names a semantic token, so the same
six selectors are a light theme on paper and a dark theme on the dark canvas,
and the well behind the code (`bg-sunk`) flips with them. The ratios on `sunk`
in both modes are recorded in that block — measure there, not on the canvas,
if you add a token to it.

Anything GitHub sent goes through `github_html` before `raw`. Wrapper markup and
data attributes are added **after** sanitizing, never through it.

---

## 10. Accessibility floor

Non-negotiable on every screen.

- **Focus is visible everywhere.** One `:focus-visible` treatment is defined in
  `@layer base` — a brand ring with an offset. Never strip it, and never
  replace it with a color change. A component may *move* it — a textarea can
  hand the ring to the card around it — but `focus:ring-0` alone leaves a 2px
  canvas-coloured band, because the offset is a separate shadow from the ring;
  zero both.
- **Contrast meets AA in both modes.** Stick to the tokens; the measured ratios
  are in §2's two tables. If you need a new color, add it as a `light-dark()`
  pair, measure both with `relative_luminance`, and add both to the tables.
- **The theme follows the device.** Nothing in a screen names a mode, and no
  screen hardcodes a colour. A dark-only override on a component is a sign the
  token is wrong (§2).
- **Nothing is conveyed by color alone.** Every pill carries a word. The change
  bar is paired with a status pill in the file list and with the block's own
  content. Reactions carry an sr-only name beside the emoji.
- **Real controls.** The gutter "+" is a `<button>`, tabs are links with
  `aria-current="page"`, the account menu is a `<details>` that works without
  JavaScript. Nothing interactive is a `<div>` with a click handler. Everything
  clickable shows a pointer, from the base layer (§5).
- **Decorative SVGs are `aria-hidden`**, including the brand mark and the
  sign-in miniature. Meaningful ones get a label.
- **No horizontal overflow at 390px.** Use `min-w-0` on flex children,
  `truncate` or `break-words` on anything from GitHub. Paths use `break-all`
  because a long path has no word boundaries.
- **Reduced motion is respected** globally: `prefers-reduced-motion` collapses
  every transition and animation to 0.01ms.
- Give sections a `data-testid` where system tests need to target them. The
  ones in use: `top-bar`, `breadcrumb`, `brand`, `account-menu`, `sign-out`,
  `sign-in`, `flash`, `empty-state`, `repo-filter`, `repo-list`, `repo-row`,
  `load-more`, `filter-empty`, `pr-tabs`, `pr-tab-<state>`,
  `pull-request-list`, `pull-request-row`, `next-page`, `pr-state`,
  `review-decision`, `pr-body`, `markdown-count`, `markdown-files`,
  `markdown-file`, `other-files`, `reviews`, `pending-review`,
  `open-on-github`, `labels`, `comment`, `rate-limit-banner`.
