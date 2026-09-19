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

### Surfaces and ink

| Token | Hex | Utility | Role |
| --- | --- | --- | --- |
| `--color-canvas` | `#F2F3F8` | `bg-canvas` | The page. Cool paper with a faint violet cast. |
| `--color-surface` | `#FFFFFF` | `bg-surface` | Panels, rows, the top bar. White is reserved for raised things, which is why panels need no shadow. |
| `--color-sunk` | `#ECEEF5` | `bg-sunk` | Wells: code blocks, inset strips, hover fills. |
| `--color-ink` | `#16182B` | `text-ink` | Primary text. Deep indigo, not a tinted black. |
| `--color-ink-soft` | `#565C78` | `text-ink-soft` | Secondary text, descriptions, metadata. |
| `--color-ink-faint` | `#6E7490` | `text-ink-faint` | Tertiary: timestamps, counts, captions. |
| `--color-line` | `#DEE1EC` | `border-line` | Every hairline. |
| `--color-line-strong` | `#C3C8DB` | `border-line-strong` | A rule that has to carry weight (table head, blockquote). |

### The spectrum

The review palette is ordered violet → blue → green → amber → red, and each
band has exactly one job. Nothing else may use these colors.

| Token | Hex | Meaning |
| --- | --- | --- |
| `--color-brand` | `#4B33CE` | Prism itself: links, primary buttons, focus ring, the brand mark, and a **merged** pull request. |
| `--color-brand-deep` | `#37209F` | Hover and pressed states on brand surfaces. |
| `--color-brand-soft` | `#ECE9FD` | Tinted fill: brand pills, active and hovered rows. |
| `--color-pending` | `#1F66C9` | An unsubmitted review — your light, not yet emitted. The tray, pending comments, `> [!NOTE]`. |
| `--color-pending-soft` | `#E1EDFB` | |
| `--color-added` | `#15795D` | Added content, additions counts, an **open** PR, an approval, `> [!TIP]`. |
| `--color-added-soft` | `#DCF1E9` | |
| `--color-modified` | `#8F5E0E` | Changed content, outdated comments, degraded-data banners, `> [!WARNING]`. |
| `--color-modified-soft` | `#FAEDD6` | |
| `--color-removed` | `#B02D3C` | Deleted content, a **closed** PR, changes requested, destructive actions, `> [!CAUTION]`. |
| `--color-removed-soft` | `#FBE3E6` | |
| `--color-resolved` | `#565C78` | A resolved thread goes quiet. Same value as `ink-soft` on purpose. |
| `--color-resolved-soft` | `#ECEEF5` | |

### Measured contrast

Every value passes WCAG AA for normal text on both the canvas and its own soft
fill. Re-measure with `relative_luminance` in `ApplicationHelper` if you change
one.

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

White text is legible on solid `brand` (7.9), `brand-deep` (11.2), `added`
(5.4), `pending` (5.5) and `removed` (6.4). It is **not** legible on
`modified` — use `modified` as text or as a border, never as a solid fill
behind white.

### Dark mode

Not shipped. Every component class reads semantic tokens, so a dark theme is a
matter of redefining the tokens and nothing else. A scaffold sits at the bottom
of `application.css` under `:root[data-theme="dark"]`; it is opt-in, has not
been reviewed on screen, and its contrast has not been measured. Taking it on
means re-running the contrast table above against the dark values and adding a
`prefers-color-scheme` branch.

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
| `.reading-shell` | `60rem` + `px-4 md:px-6` | The rendered file view. A plain column, **not** a grid — see below. |
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

Prose inside `.md-prose` is capped at `--measure-prose` (72ch). Tables, code
blocks, images, `<details>` and alerts are allowed the full column width,
because wrapping a table is worse than a long line.

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

Almost none. Panels are defined by a border on white over the canvas, never by
a shadow. The only shadows in the system are on things that float above the
page: the account menu (`shadow-lg shadow-ink/5`) and, later, the composer
popover. Adding a shadow to a card is a bug.

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
| `style-src` | `'self' https://fonts.googleapis.com` + nonce | The Tailwind build, the Google Fonts link, and the `<style>` Turbo injects for its progress bar — Turbo reads `csp-nonce` and sets it on that element. |
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
Prism emits comes from `label_pill_style`, which matches GitHub's hex against
`\A\h{6}\z` and re-emits it through `format("#%02x%02x%02x")`, so the value
cannot carry anything but three numbers — and `style` is not in
`GITHUB_HTML_ATTRIBUTES`, so the sanitizer strips it from every piece of
GitHub-authored HTML. Note that `style-src-attr` deliberately carries **no**
nonce: adding one would cancel the `unsafe-inline` the labels depend on.

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

| Class | What / when |
| --- | --- |
| `.shell` / `.shell-narrow` / `.reading-shell` | The three content widths (§4). |
| `.topbar` / `.topbar-inner` / `.topbar-seam` | Sticky top bar and its spectrum rule. Rendered by the layout. |
| `.panel` / `.panel-head` / `.panel-title` | The bordered container every list lives in. |
| `.row` | A static row inside a panel. |
| `.row-link` | A row that navigates: hover fill plus a brand tick on the left edge. |
| `.row-title` / `.row-meta` | A row's headline and its metadata line. |
| `.section-head` / `.section-title` / `.section-note` | A section's name over a hairline, with an optional right-hand note. |
| `.btn` + `.btn-primary` / `.btn-secondary` / `.btn-ghost` / `.btn-danger` | Buttons. `.btn-lg` and `.btn-sm` adjust size. One primary per screen. |
| `.field-label` / `.field-input` / `.field-search` / `.field-hint` | Forms. `.field-search` adds room for a leading icon. |
| `.pill` + `.pill-neutral` / `-brand` / `-pending` / `-added` / `-modified` / `-removed` / `-resolved` | Every status pill. `.pill-solid` is the heavier variant for a PR header. |
| `.label-pill` | A GitHub label. Colors come from `label_pill_style(hex)`. |
| `.mono-tag` | Branch names, paths, SHAs — anything retypable. |
| `.avatar` / `.avatar-sq` | Round for people, squared for repositories and orgs. |
| `.tabs` / `.tab` / `.tab-active` | Underline tabs. |
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
| `_page_header` | A browsing screen's title block. Locals: `title:` (required, string or `capture`d HTML), `subtitle:`, `meta:`, `actions:`. |
| `_empty_state` | Locals: `title:` (required), `body:`, `icon:` `:prism`/`:repo`/`:pull`/`:file`/`:search`, `cta_label:` + `cta_to:`. |
| `_labels` | GitHub labels in the repo's colors. Locals: `labels:` (array of `Github::Types::Label`), `limit:` (then "+N more"). |
| `_rate_limit_banner` | Locals: `retry_in:` (seconds, from `Github::RateLimited#retry_in`) and `reset_at:` as a fallback. Use above content that rendered anyway. |
| `_comment_card` | One review comment: avatar, login, time, pending/outdated pills, prose body, reaction pills. Locals: `comment:` (required), `actions:` (safe HTML for the action row). **This is the reference for all comment styling** — extend it with `actions:`, don't restyle it. |
| `not_found` / `forbidden` / `rate_limited` | Full-page error screens rendered by `GithubErrorHandling`. |

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
   on a phone and is `aria-hidden`.
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
5. **Rendered file view** — workstream D. Built from `.reading-shell`, §7 and
   §8. Sticky top bar, reading column, per-block gutter, removed strips,
   threads under their block, sticky pending-review tray, outdated section at
   the bottom.
6. **Error screens** — `GithubErrorHandling` turns `Github::NotFound` into a
   friendly 404 that says GitHub answers the same way for a missing and a
   private repository, `Github::Forbidden` into an org-approval explanation, and
   `Github::RateLimited` into a page that says when the limit resets. Use
   `_rate_limit_banner` instead when the page rendered anyway with stale data.

---

## 7. Review gutter

The primitives the rendered file view is built from. Workstream D writes the
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
| `.md-block--added` / `--modified` / `--removed` | Sets the change bar's color, and tints `.md-body` very faintly for added and modified. The tint is 42% of the soft fill — a skim should find the changes without the page becoming a diff. |
| `.md-gutter` | The gutter cell. |
| `.md-gutter-bar` | The 3px change bar, full block height. Transparent when unchanged, so an unchanged page is just the document. |
| `.md-body` | The block's content cell. |
| `.md-add` | The "+" affordance. `opacity-0` until `.md-block:hover` or `:focus-within`, and always reachable by keyboard because it is a real focusable button. |
| `.md-add--muted` | For a block GitHub can't anchor a line comment to. Dashed border, muted color. **It still works** — it opens the composer in file-comment mode. The difference must be visible before the click, and the reason must be stated in words in the composer. |
| `.filebar` / `.filebar-inner` | The per-file bar under the app top bar: file switcher, prev/next, change count. Sticks at `var(--topbar-height)`. `.filebar-inner` is capped at `--measure-read` so it lines up with the document. |
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
- **Two cascade traps, both already handled — don't undo them.** The phone
  rule for the block's "+" carries `:not(.md-add--child):not(.md-add--row)`,
  because it is two classes and the child rules are one, so without the
  exclusions it collapses every child button onto the left edge of its own
  `<li>`. And the compiler reorders rules, so an override of equal specificity
  is not guaranteed to win — scope a rule to the width where it applies rather
  than setting it always and overriding it.

---

## 8. Comment cards, threads and the tray

| Class | What / when |
| --- | --- |
| `.thread` | Wraps a stack of comment cards. Modifiers: `.thread--pending` (blue, an unsubmitted draft), `.thread--resolved` (grey, gone quiet), `.thread--outdated` (amber edge). |
| `.comment-card` | One comment. Hairline-separated inside a thread. |
| `.comment-head` / `.comment-author` | Avatar, login, relative time, pending/outdated pills, and a right-aligned "On GitHub" link. |
| `.comment-body` | The body. Always `md-prose md-prose-compact`. |
| `.comment-actions` | The row under the body: reactions first, then your actions. |
| `.reaction-pill` / `.reaction-pill--on` | A reaction. The `--on` state is filled in brand, so the toggle reads without counting. |
| `.reply-box` | The reply field at the foot of a thread. |
| `.composer-textarea` | The comment textarea — serif, because you are writing prose about prose. |
| `.tray` / `.tray-inner` | The sticky pending-review bar. `.tray-inner` is capped at `--measure-read` so it lines up with the document above it. Render it into `content_for :tray`, which the layout yields after `<main>`. |

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

**Code highlighting** — a light Rouge theme is defined at the end of
`application.css` against `.md-prose .highlight`. Comments recede to
`ink-faint` italic, keywords take the violet end, strings the green, numbers the
amber, class and function names the blue. `.gd` / `.gi` (diff removed/added)
use the removed and added soft fills.

Anything GitHub sent goes through `github_html` before `raw`. Wrapper markup and
data attributes are added **after** sanitizing, never through it.

---

## 10. Accessibility floor

Non-negotiable on every screen.

- **Focus is visible everywhere.** One `:focus-visible` treatment is defined in
  `@layer base` — a brand ring with an offset. Never strip it, and never
  replace it with a color change.
- **Contrast meets AA.** Stick to the tokens; the measured ratios are in §2. If
  you need a new color, measure it with `relative_luminance` and add it to the
  table.
- **Nothing is conveyed by color alone.** Every pill carries a word. The change
  bar is paired with a status pill in the file list and with the block's own
  content. Reactions carry an sr-only name beside the emoji.
- **Real controls.** The gutter "+" is a `<button>`, tabs are links with
  `aria-current="page"`, the account menu is a `<details>` that works without
  JavaScript. Nothing interactive is a `<div>` with a click handler.
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
