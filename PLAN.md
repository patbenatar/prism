# Prism — Plan & Architecture

Prism is a code-review layer on top of GitHub, built for the agentic era: humans
increasingly review work that agents wrote, and GitHub's diff UI is the wrong
lens for a lot of that work. Prism starts with one sharp feature and is named
and structured to grow into a broader review assistant.

**Feature 1 (this plan): review a pull request's Markdown files *rendered*, and
leave GitHub review comments on rendered blocks.** GitHub only lets you comment
on source lines in the diff. Prism renders the Markdown, lets you comment on a
paragraph / heading / list item / table / code block, translates that to the
right source line(s), and posts a real GitHub review comment. Existing GitHub
comments show up next to the rendered block they belong to.

Non-goals for feature 1: commenting on arbitrary text selections (the unit of
granularity is a *block*, because GitHub's unit is a *line*); reviewing
non-Markdown files (we link out to GitHub); storing any review data ourselves.

---

## Principles

1. **GitHub is the only source of truth.** Prism persists users and their OAuth
   tokens, nothing else. No comments, no drafts, no PR state. A pending review
   lives *on GitHub* (as a pending `PullRequestReview`), so refreshing the page
   loses nothing. If Prism disappeared tomorrow every comment would still be on
   GitHub, indistinguishable from one left in the GitHub UI.
2. **Best-effort, transparent translation.** Rendered block ⇄ source line is a
   heuristic with known limits (GitHub only accepts comments on lines that
   appear in the diff). Prism always shows *why* a block isn't commentable and
   never silently drops or mis-anchors a comment.
3. **Feature parity with GitHub commenting is the bar.** Single comments,
   batched reviews (Approve / Request changes / Comment), replies, edit/delete
   own comments, resolve/unresolve threads, reactions, @-mentions with
   autocomplete, Markdown bodies with preview, outdated-comment handling.
4. **Same house style as MealMate and Sprout**: Rails 8.1, Hotwire (Turbo +
   Stimulus via importmap, no Node build), Tailwind 4, Propshaft, Postgres,
   Solid Cache/Queue/Cable, Minitest + Capybara system tests, everything in
   Docker, thin controllers + service objects, `data-testid` hooks in views.
5. **Desktop-first, responsive.** Unlike Sprout/MealMate (phone-first), code
   review happens on a laptop. Layout is a wide reading column with a comment
   gutter, and it must still degrade gracefully to a phone (no horizontal
   overflow, stack the gutter under the block).

---

## Stack

| Concern | Choice |
| --- | --- |
| Framework | Rails 8.1.x, Ruby 3.4.9, module `PrismApp` (the `Prism` constant belongs to Ruby's parser gem, which Rails loads) |
| DB | Postgres 16 (users only) + Solid Cache for GitHub response caching |
| Auth | GitHub OAuth App via `omniauth-github` + `omniauth-rails_csrf_protection`; token stored with ActiveRecord Encryption |
| GitHub API | `octokit` 10 (REST) + `Github::GraphQL` over `client.post("/graphql")` (threads, pending-review drafts, reactions, resolve) |
| Markdown | `commonmarker` 2.10 (comrak) driven through its AST with `sourcepos`; `rouge` for code highlighting; `Rails::HTML5::SafeListSanitizer` with a custom safelist |
| Frontend | Turbo Frames/Streams, Stimulus, Tailwind 4; hand-rolled Stimulus controller for @-mention autocomplete (no extra importmap pins) |
| Tests | Minitest, Capybara + headless Chromium, WebMock (network is disabled in tests; GitHub is always stubbed) |
| Dev | Docker Compose: `app` (host :3004), `postgres` (host :5436), `css` watcher. No mailpit (no email). |

---

## Data model (database)

Deliberately tiny.

```
users
  id, github_id (bigint, unique), login, name, avatar_url,
  access_token (encrypted), token_scopes, last_signed_in_at, timestamps
```

Session = Rails cookie session holding `user_id`. No `sessions` table for v1.

Everything else (repos, pull requests, files, comments, reviews, threads,
collaborators) is fetched from GitHub on demand and cached in `Rails.cache`
(Solid Cache) with short TTLs, keyed by the user's token so private data never
leaks across users. Immutable things (file contents at a commit sha, a PR's
`patch` at a head sha) get long TTLs.

---

## Domain architecture

```
app/
├── controllers/
│   ├── sessions_controller.rb            # OmniAuth callback, sign out
│   ├── repos_controller.rb               # index (list/search)
│   ├── pull_requests_controller.rb       # index (per repo), show (overview)
│   ├── pull_request_files_controller.rb  # show (the rendered Markdown view)
│   ├── review_comments_controller.rb     # create / reply / update / destroy
│   ├── reviews_controller.rb             # create pending, submit, discard
│   ├── review_threads_controller.rb      # resolve / unresolve
│   ├── reactions_controller.rb           # create / destroy on a comment
│   ├── mentionables_controller.rb        # JSON for @-autocomplete
│   └── markdown_previews_controller.rb   # render a comment body via GitHub
├── models/
│   └── user.rb
├── services/
│   ├── github/
│   │   ├── client.rb          # thin wrapper over Octokit + GraphQL; caching; errors
│   │   ├── graphql.rb         # POST /graphql helper
│   │   └── types.rb           # Data.define value objects (Repo, PullRequest, PullRequestFile, ReviewComment, Review, ReviewThread, Mentionable, Reaction)
│   ├── markdown/
│   │   ├── renderer.rb        # commonmarker AST walk → [Block] with sanitized HTML + source ranges
│   │   ├── document.rb        # Block list + lookups (block covering line N, text of a block)
│   │   ├── block.rb
│   │   ├── sanitizer.rb       # SafeListSanitizer with the Prism safelist
│   │   └── highlighter.rb     # Rouge over pre[lang]
│   ├── diff/
│   │   └── patch.rb           # unified-diff hunk parser → Diff::LineSets (right/left kinds, right_of_left)
│   └── review/
│       ├── anchor.rb          # Data.define value object; to_rest / to_graphql
│       ├── anchor_resolver.rb # block + line sets → Anchor or :outside_diff
│       ├── block_mapper.rb    # (head blocks, base blocks, line sets, threads) → [AnnotatedBlock] + outdated + file-level buckets
│       └── file_comment_body.rb # builds the quoted-block + permalink body for file-level fallback comments
└── javascript/controllers/
    ├── block_gutter_controller.js     # hover "+" per block, open composer
    ├── comment_composer_controller.js # textarea, Cmd+Enter, preview tab, autosize
    ├── mention_controller.js          # @ autocomplete against /mentionables
    ├── pending_review_controller.js   # sticky "N pending · Submit review" tray
    └── collapse_controller.js         # removed-content strips, outdated section
```

Rules:

- **Controllers are thin.** They authenticate, build a `Github::Client` for
  `current_user`, call a service, render. No Octokit calls in controllers or
  views.
- **`Github::Client` is the only thing that talks to GitHub.** It returns
  `Data.define` value objects from `Github::Types`, never raw Sawyer resources,
  so the rest of the app (and tests) depend on a stable, small interface.
- **`Markdown::*` and `Diff::*` and `Review::*` are pure Ruby.** No Rails
  request context, no GitHub calls; they take strings/value objects and return
  value objects. This is where the hard logic lives and where the unit tests
  are exhaustive.
- **Views render blocks via one partial** (`pull_request_files/_block.html.erb`)
  that wraps the block's HTML with the data attributes the Stimulus controllers
  need. Comment threads render via `review_comments/_thread.html.erb` and
  `_comment.html.erb`, each with a `dom_id`-style stable id so Turbo Streams
  can replace them.

### `Github::Client` interface (contract for parallel work)

Everything below returns value objects (or arrays of them) from `Github::Types`.
Workstreams B and C code against this contract while A implements it. REST goes
through Octokit 10; GraphQL goes through `client.post("/graphql", {query:,
variables:})` (Octokit has no GraphQL support but its generic `post` sends the
hash as the JSON body; GraphQL returns HTTP 200 on errors, so `Github::GraphQL`
must raise on a non-empty `errors` key). **GraphQL is mandatory**: review
threads, `isResolved`/`isOutdated`, `bodyHTML`, `viewerCan*`, reactions with
`viewerHasReacted`, resolve/unresolve, and adding a comment to an existing
pending review exist only there.

```ruby
client = Github::Client.new(user)          # uses user.access_token; never Octokit globals

# reads (REST unless noted)
client.viewer                               # → Author (login, avatar_url, html_url) + name
client.repos(page: 1)                       # → [Repo]  GET /user/repos?sort=pushed&direction=desc&per_page=100 (one page; caller paginates; filter in-browser)
client.repo(owner, name)                    # → Repo
client.pull_requests(owner, name, state: "open", page: 1)  # → [PullRequest]  sort=updated desc
client.pull_request(owner, name, number)    # → PullRequest (node_id, head_sha, base_sha, body, author, state, draft, labels, changed_files…)
client.pull_request_files(owner, name, number)             # → [PullRequestFile] auto-paginated (≤3000)
client.file_content(owner, name, path, ref:)               # → String (UTF-8, Accept: application/vnd.github.raw) or nil on 404
client.reviews(owner, name, number)                        # → [Review] (PENDING ones have no submitted_at)
client.pending_review(owner, name, number)                 # → Review or nil (viewer's PENDING review)
client.review_threads(owner, name, number)                 # → ReviewThreadsResult (pull_request_node_id, [ReviewThread with nested [ReviewComment]]) via GraphQL, fully paginated
client.mentionables(owner, name, participants: [])         # → [Mentionable] collaborators (403 → assignees) ∪ org members (if owner is an org) ∪ participants; cached 10 min
client.render_markdown(text, context: "owner/name")        # → HTML String via POST /markdown mode=gfm (preview only; cached by digest)

# writes
client.create_thread(pull_request_node_id:, anchor:, body:)                 # GraphQL addPullRequestReviewThread(pullRequestId:) → posts immediately; anchor may be FILE-level
client.add_thread_to_review(review_node_id:, anchor:, body:)               # GraphQL addPullRequestReviewThread(pullRequestReviewId:) → draft in pending review
client.reply(owner, name, number, root_comment_id, body:)                   # REST POST .../comments/{id}/replies (immediate)
client.reply_in_review(review_node_id:, thread_node_id:, body:)            # GraphQL addPullRequestReviewThreadReply (draft)
client.update_comment(comment_node_id, body:)                              # GraphQL updatePullRequestReviewComment (works for pending too)
client.delete_comment(comment_node_id)                                     # GraphQL deletePullRequestReviewComment
client.create_pending_review(owner, name, number, commit_id:)              # REST POST .../reviews with no event → Review(PENDING); 422 → reuse existing
client.submit_review(owner, name, number, review_id, event:, body: nil)    # REST POST .../reviews/{id}/events; event APPROVE|REQUEST_CHANGES|COMMENT (body required except APPROVE)
client.delete_pending_review(owner, name, number, review_id)               # REST DELETE
client.resolve_thread(thread_node_id) / client.unresolve_thread(thread_node_id)  # GraphQL
client.add_reaction(comment_node_id, content:) / client.remove_reaction(comment_node_id, content:)  # GraphQL; content is REST-style (+1 -1 laugh confused heart hooray rocket eyes), client maps to THUMBS_UP…
```

Writes always pass `commit_id: pull_request.head_sha` fetched fresh on the
request (a stale sha after a force-push 422s; surface "PR was updated, reload").
Writes are made serially per request; no client-side batching in v1.

Errors are normalized to `Github::Error` subclasses: `Unauthorized` (401 → clear
token, sign out), `Forbidden`, `NotFound` (also what a private repo the token
can't see returns), `RateLimited` (403/429 with `reset_at` / `retry_after`),
`LineNotCommentable` (422 whose message includes "must be part of the diff"),
`Unprocessable` (other 422 with GitHub's message), `GraphQLError`, `Unavailable`.

### Value objects (`Github::Types`)

```ruby
Author          = Data.define(:login, :avatar_url, :html_url)
Label           = Data.define(:name, :color)
Repo            = Data.define(:id, :owner, :name, :full_name, :private, :description, :default_branch, :pushed_at, :open_issues_count, :html_url, :owner_avatar_url, :owner_type)
PullRequest     = Data.define(:number, :node_id, :title, :body, :state, :draft, :merged, :author, :head_sha, :base_sha, :head_ref, :base_ref, :created_at, :updated_at, :labels, :html_url, :changed_files, :additions, :deletions)
PullRequestFile = Data.define(:path, :previous_path, :status, :additions, :deletions, :patch, :blob_url) do
  def markdown? = path.match?(/\.(md|markdown|mdx)\z/i)
end
Review          = Data.define(:id, :node_id, :state, :body, :author, :submitted_at, :commit_id, :html_url)   # PENDING APPROVED CHANGES_REQUESTED COMMENTED DISMISSED
ReviewThread    = Data.define(:node_id, :path, :line, :original_line, :start_line, :original_start_line, :diff_side, :start_diff_side, :subject_type, :is_resolved, :is_outdated, :resolved_by, :viewer_can_resolve, :viewer_can_unresolve, :viewer_can_reply, :comments)
ReviewComment   = Data.define(:id, :node_id, :author, :body, :body_html, :state, :created_at, :url, :diff_hunk, :outdated, :viewer_can_update, :viewer_can_delete, :viewer_can_react, :reply_to_node_id, :reaction_groups)  # id = REST databaseId; state PENDING|SUBMITTED
ReactionGroup   = Data.define(:content, :count, :viewer_has_reacted)   # content in REST style: +1 -1 laugh confused heart hooray rocket eyes
Mentionable     = Data.define(:login, :name, :avatar_url)
ReviewThreadsResult = Data.define(:pull_request_node_id, :threads)
```

### Markdown engine (`Markdown::*`, `Diff::*`, `Review::*`)

`docs/research/markdown-mapping.md` and `docs/research/github-api.md` hold the
verified research (commonmarker behaviour was tested on aarch64; API rules were
checked against GitHub's docs and GraphQL schema). The rules below are binding.

**The central constraint.** GitHub accepts a review comment only on a line that
appears inside one of the file's diff hunks (`patch`): added lines, deleted
lines, and the ~3 context lines around each change. Anything else fails with
`422 "Pull request review thread line must be part of the diff"`, from REST and
GraphQL alike, even though github.com's own UI can comment on expanded context.
So in a rendered file most blocks may be uncommentable at line level. Prism
handles this deliberately (see "Uncommentable blocks" below), never silently.

- `Markdown::Renderer` walks the **commonmarker AST** (`Commonmarker.parse`,
  `node.source_position`, per-node `to_html`) instead of parsing the HTML
  renderer's output, because raw HTML blocks get no `data-sourcepos` in the
  HTML output but do in the AST. Options: GFM extensions (table, tasklist,
  strikethrough, autolink, tagfilter, footnotes, `header_ids: "user-content-"`,
  `front_matter_delimiter: "---"`, alerts, math), render `sourcepos: true`,
  `unsafe: true`, **`hardbreaks: false`** (GitHub uses soft breaks in `.md`
  files), `github_pre_lang: true`; syntect highlighter disabled, Rouge applied
  to `pre[lang]` afterwards. Every block's HTML goes through
  `Markdown::Sanitizer` (Rails::HTML5::SafeListSanitizer with a custom safelist
  that keeps tables, task-list inputs, details/summary, `data-sourcepos`, ids,
  and strips `style`, event handlers and `javascript:` URLs). Known comrak
  quirks are normalized: the last `<li>` of a tight list reports
  `end_line + 1` with `end_column == 0` (clamp it); `<details>` wrapping
  Markdown parses as two `html_block` nodes and must be coalesced into one
  `html_region` block (capped so a pathological file can't swallow the rest);
  fenced code ranges include the closing fence and setext headings include the
  underline (keep). BOM stripped, CRLF normalized; **lines only, never columns**.
- `Markdown::Document.parse(text)` → `[Markdown::Block]`: the **commentable
  unit** is a top-level block (paragraph, heading, list, table, fenced code,
  blockquote, alert, html_region, thematic break, front matter rendered as a
  collapsed metadata table) plus nested list items and table rows for finer
  granularity. Block: `id` (stable: index + range + content hash), `type`,
  `start_line`, `end_line`, `html`, `depth`, `parent_id`.
- `Diff::Patch.parse(patch)` → `Diff::LineSets`: `right` (Hash head_line →
  `:added|:context`), `left` (Hash base_line → `:removed|:context`),
  `right_of_left` (base line → the head line now sitting where it was; a
  **display convention only, never a write anchor**). Hunk counts are optional
  in `@@ -a[,b] +c[,d] @@`; `\ No newline at end of file` consumes no line; an
  **empty-string context line must count as context** or every later line in
  the hunk is off by one. `nil`/absent patch (binary, pure rename, >500 KB
  diff) → empty sets.
- `Review::AnchorResolver.call(block, line_sets)` → `Review::Anchor` or a
  reason. Rules: in-diff lines of the block = `block.lines ∩ right.keys`.
  Contiguous run of ≥2 → **multi-line** anchor `start_line..line` on RIGHT
  (GitHub highlights the whole range). Otherwise single line: first *added*
  line in the block, else first in-diff line. Empty → not line-commentable →
  `:outside_diff`, and the UI offers a **file-level comment** instead.
  `Review::Anchor = Data.define(:path, :subject_type, :side, :line, :start_side, :start_line)`
  serializes to both REST (`line/side/start_line/start_side/subject_type`) and
  GraphQL (`line/side/startLine/startSide/subjectType`) shapes. A LEFT anchor
  always carries a **base-side** line number.
- `Review::BlockMapper.call(head_blocks:, base_blocks:, line_sets:, threads:)`
  → ordered `[Review::AnnotatedBlock]` for the view: `block`,
  `change: :added | :modified | :unchanged` (added iff any line is added;
  modified iff any base line inside its hunk was removed; a block spanning two
  hunks is highlighted whole), `commentable` + `uncommentable_reason`,
  `anchor`, `threads`, and `removed_before: [Markdown::Block]` (base blocks
  whose lines are **all** deletions, rendered from the base file and shown as a
  collapsed strip right before the head block that now occupies that spot, via
  `right_of_left`).
- **Placing existing threads** (from the GraphQL `reviewThreads` query):
  `isOutdated` or `line == nil` → **Outdated** section at the bottom (show
  `originalLine` + `diffHunk`; never guess a block). `diffSide == RIGHT` →
  block whose range covers `line`. `diffSide == LEFT` → map through
  `right_of_left` to the head block, render in a muted "on removed content"
  style quoting the deleted text; if no block, attach to the removed strip.
  `subjectType == FILE` → **File comments** section at the top of the file.
- **Uncommentable blocks (product decision).** Every block still shows a
  gutter affordance on hover. For blocks outside the diff it is muted and
  opens the composer in *file-comment mode*: a one-line explanation ("This
  block isn't part of the PR diff, so GitHub can't anchor a comment to it.
  Prism will post it as a file-level comment quoting the block."), and the
  body is pre-filled with a blockquote of the block's text (trimmed) plus a
  permalink `https://github.com/{owner}/{repo}/blob/{head_sha}/{path}#L{start}-L{end}`.
  Posted with `subject_type: "file"`.
- **Base side**: v1 renders HEAD only plus removed strips. A `removed` file
  renders the BASE content with everything marked removed and commenting on
  LEFT lines. A pure rename with no patch renders with nothing line-commentable.
- **Golden fixtures** pin comrak's sourcepos: tight/loose/nested lists,
  multi-paragraph items, tables (incl. header-only), fenced + indented code,
  setext headings, front matter, alerts, footnotes, nested blockquotes,
  `<details>` wrapping Markdown, CRLF, BOM, no trailing newline, file ending
  in a list item. Plus the invariant test: block ranges are in-file, ordered,
  and never overlap.

---

## Routes

GitHub-shaped URLs so a reviewer can swap the host to jump between Prism and
GitHub.

```ruby
root "repos#index"

get    "/sign_in",                 to: "sessions#new"
# POST /auth/github is handled by OmniAuth middleware (omniauth-rails_csrf_protection: the sign-in link must be a button_to POST)
get    "/auth/github/callback",    to: "sessions#create"
get    "/auth/failure",            to: "sessions#failure"
delete "/session",                 to: "sessions#destroy", as: :session

get "/repos", to: "repos#index", as: :repos           # ?q= search, paginated

scope "/:owner/:repo", constraints: { owner: /[^\/]+/, repo: /[^\/]+/ }, as: :repo do
  get  "pulls",                to: "pull_requests#index"   # ?state=open|closed|all
  get  "pulls/:number",        to: "pull_requests#show",  as: :pull
  get  "pulls/:number/files/*path", to: "pull_request_files#show", as: :pull_file, format: false

  scope "pulls/:number", as: :pull do
    post   "comments",                          to: "review_comments#create"
    post   "comments/:id/replies",              to: "review_comments#reply",   as: :comment_replies
    patch  "comments/:id",                      to: "review_comments#update",  as: :comment
    delete "comments/:id",                      to: "review_comments#destroy"
    post   "comments/:id/reactions",            to: "reactions#create",        as: :comment_reactions
    delete "comments/:id/reactions/:reaction_id", to: "reactions#destroy",     as: :comment_reaction
    post   "reviews",                           to: "reviews#create"          # start pending review
    post   "reviews/:id/submit",                to: "reviews#submit",          as: :review_submit
    delete "reviews/:id",                       to: "reviews#destroy",         as: :review
    post   "threads/:id/resolve",               to: "review_threads#resolve",  as: :thread_resolve
    post   "threads/:id/unresolve",             to: "review_threads#unresolve", as: :thread_unresolve
  end

  get  "mentionables",      to: "mentionables#index"         # JSON
  post "markdown/preview",  to: "markdown_previews#create"   # HTML fragment
end
```

All routes except `sign_in` and the auth callbacks require a signed-in user.
Every GitHub call is made *as that user* with their token, so authorization is
GitHub's; Prism never sees data the user couldn't see on github.com.

---

## Screen map

1. **Sign in** (`/sign_in`): one big "Continue with GitHub" button, one line of
   what Prism does, scopes explained in a sentence.
2. **Repositories** (`/repos`): search box (filters as you type, Turbo Frame),
   list of repos the user can access sorted by recent push; each row: owner
   avatar, `owner/name`, private lock, description, open PR count, pushed
   "2h ago". Click → PRs.
3. **Pull requests** (`/:owner/:repo/pulls`): tabs Open / Closed / All;
   each row: title, `#number opened 3d ago by author`, draft badge, labels,
   review decision pill (Approved / Changes requested / Review required),
   files-changed count, and a **"N Markdown files"** pill because that's what
   Prism is for. Click → PR overview.
4. **PR overview** (`/:owner/:repo/pulls/:n`): header (title, number, state
   pill, base ← head, author, updated); PR description rendered; file list with
   `.md` files first and highlighted (additions/deletions per file), other
   files greyed with a "view on GitHub" link; reviews summary (who approved /
   requested changes); "Open on GitHub" link. Click a Markdown file → file view.
5. **Rendered file view** (`/:owner/:repo/pulls/:n/files/docs/foo.md`) — the
   core screen:
   - Sticky top bar: repo / PR title / file switcher (dropdown of the PR's
     `.md` files with change counts, prev/next), "View source diff on GitHub".
   - Reading column (max ~80ch of prose, wider for tables/code) of rendered
     Markdown. Each block has a left gutter: a change bar (green = added,
     amber = modified, none = unchanged), and on hover a **+** button (like
     GitHub's) if the block is commentable. Uncommentable blocks show a muted
     tooltip explaining why.
   - Collapsed **removed** strips where base blocks were deleted ("2 blocks
     removed · show"), expanding to a red-tinted rendering of the old content.
   - **Threads** render directly under their block in a comment card: avatar,
     login, relative time, body (GitHub-rendered HTML), reactions row, reply
     box, Resolve / Unresolve, Edit / Delete on your own comments, "outdated"
     badge, link to the comment on GitHub.
   - Clicking **+** opens the **composer** under the block (Turbo Frame):
     textarea with @-mention autocomplete and Markdown preview tab; buttons
     **Add single comment** (posts immediately) and **Start a review** /
     **Add review comment** (adds to the pending review). Cmd/Ctrl+Enter
     submits. Shows the source anchor it will use ("lines 12–18") so the
     translation is transparent.
   - Sticky bottom **pending review tray** when a pending review exists: "3
     pending comments" · **Submit review** (opens a panel: optional body,
     Approve / Request changes / Comment) · Discard.
   - **Outdated** section at the bottom for comments GitHub can no longer
     place.
   - Empty/edge states: file removed in this PR (render base with everything
     marked removed, commenting only on LEFT-side lines), file added (all
     blocks green), file too large / no patch (render, nothing commentable,
     explain), non-UTF-8 (fall back to link).
6. **Account menu**: avatar top-right → GitHub profile link, Sign out.

---

## Commenting: GitHub parity checklist

| Capability | v1 | Notes |
| --- | --- | --- |
| Single comment on a block | ✅ | GraphQL `addPullRequestReviewThread(pullRequestId:)` with the block's anchor |
| Multi-line (block range) | ✅ | when the block's in-diff lines are a contiguous run; GitHub highlights the range |
| Blocks outside the diff | ✅ | file-level comment (`subjectType: FILE`) quoting the block + permalink, explained in the composer |
| Start / add to / submit pending review | ✅ | pending review lives on GitHub (one per user per PR); add via GraphQL `addPullRequestReviewThread(pullRequestReviewId:)`; rehydrated on load from `state: PENDING` comments |
| Approve / Request changes / Comment | ✅ | |
| Discard pending review | ✅ | |
| Reply in thread | ✅ | |
| Edit / delete own comment | ✅ | |
| Resolve / unresolve thread | ✅ | GraphQL |
| Reactions | ✅ | GraphQL `addReaction`/`removeReaction`; `viewerHasReacted` drives toggle state |
| @-mentions with autocomplete | ✅ | collaborators + org members + PR participants |
| Markdown preview | ✅ | GitHub `POST /markdown` (mode gfm, context owner/repo), debounced, cached by digest; existing comments use GraphQL `bodyHTML` (free) |
| Outdated comments | ✅ | `isOutdated` → Outdated section with `originalLine` + `diffHunk`; never guessed into a block |
| Comments on deleted content | ✅ | LEFT-side threads placed via `right_of_left`, muted style, or on the removed strip |
| Edit/Delete/Resolve affordances | ✅ | gated on `viewerCanUpdate` / `viewerCanDelete` / `viewerCanResolve`, not on login comparison |
| `#123` issue autocomplete | later | |
| ```suggestion blocks | later | possible: we know the source lines |
| Emoji `:shortcode:` autocomplete | later | |
| Selection-level commenting | never (v1) | GitHub's unit is a line |

---

## Caching, limits, failure modes

- `Rails.cache` (Solid Cache) namespace per user id. TTLs: repos 60s, PR list
  30s, PR 15s, PR files 15s (patch is per head sha → cache by sha for 1 day),
  file contents by sha 7 days, threads/reviews **not cached** (always fresh; GraphQL has no ETags),
  mentionables 10 min, viewer 1 h, `/markdown` previews by SHA256(body+context) 1 day.
- Secondary rate limits: content-creating requests are capped at 80/min and
  500/h per user, POSTs cost 5 points against a 900/min/endpoint budget. v1
  makes writes serially inside the request and surfaces `RateLimited` with the
  reset time; a per-user Solid Queue writer is a later step if bursts appear.
- Conditional requests (ETag) via Octokit's Faraday cache middleware if cheap;
  otherwise rely on the TTLs above.
- 401 from GitHub → clear session, redirect to sign in with a flash.
- 403 rate limit → render the page with a banner ("GitHub rate limit; resets
  in 12 min") using cached data when we have it.
- 422 on comment create → surface GitHub's message inline in the composer and
  keep the user's text. `LineNotCommentable` should be unreachable because the
  resolver validates first; if it happens, offer the file-level fallback.
- 422 on pending review create (one already exists) → look it up and reuse it.
- Large PRs: GitHub returns at most 3000 files and omits `patch` over ~ 20 KB
  of diff per file; blocks in those files are uncommentable with an
  explanation.

---

## Testing strategy

- **Unit (fast, most of the suite)**: `Markdown::Document` / `Diff::Patch` /
  `Review::BlockMapper` / `Review::AnchorResolver` against fixture Markdown in
  `test/fixtures/markdown/` (nested lists, tables, fenced code with/without
  trailing newline, setext headings, frontmatter, CRLF, HTML blocks, footnotes,
  task lists). Pin sourcepos behaviour so a comrak upgrade can't silently shift
  anchors.
- **`Github::Client`**: WebMock against recorded-style JSON fixtures in
  `test/fixtures/github/`; assert request bodies for every write method.
- **Integration**: every controller action, signed-in vs not, with the GitHub
  client stubbed at the HTTP layer (WebMock) via helpers in
  `test/support/github_stubs.rb` (`stub_github_pull_request(...)` etc.).
- **System (required per feature)**: Capybara drives sign-in (OmniAuth test
  mode), opens a PR's Markdown file, hovers a block, clicks +, types a comment
  with an @-mention, submits, and asserts the thread appears; the WebMock stubs
  assert the POST to GitHub carried the right `path`/`line`/`side`. Also:
  start review → add two comments → submit Approve; reply; resolve.

---

## Build phases & workstreams

**Phase 0 — Scaffold (done):** `rails new`, Docker, gems, AGENTS.md.

**Phase 1 — three parallel workstreams (independent files, contract above):**

- **A. Auth + GitHub client** *(well-defined → Sonnet)*: `User`, OmniAuth,
  `SessionsController`, `Github::Client` + `Github::Types` + `Github::GraphQL`
  + errors + caching, WebMock fixtures and `test/support/github_stubs.rb`,
  unit + integration tests. Owns: `app/models/user.rb`, `app/services/github/**`,
  `app/controllers/sessions_controller.rb`, `app/controllers/concerns/authentication.rb`,
  `config/initializers/omniauth.rb`, migrations, `test/services/github/**`,
  `test/support/**`, `test/fixtures/github/**`.
- **B. Markdown engine** *(ambiguous, core → Opus)*: `Markdown::*`, `Diff::*`,
  `Review::*` pure Ruby with exhaustive fixtures/tests. Owns:
  `app/services/{markdown,diff,review}/**`, `test/services/{markdown,diff,review}/**`,
  `test/fixtures/markdown/**`, `docs/markdown-mapping.md`.
- **C. Design system + shell + browsing screens** *(design → Opus)*:
  `DESIGN.md`, Tailwind theme, layout, `shared/` partials, sign-in page,
  Repos / Pull requests / PR overview screens coded against the
  `Github::Client` contract (stubbed in tests). Owns: `app/assets/tailwind/**`,
  `app/views/layouts/**`, `app/views/shared/**`, `app/views/{sessions,repos,pull_requests}/**`,
  `app/controllers/{repos,pull_requests}_controller.rb`, `app/helpers/**`,
  `config/routes.rb` (C is the routes owner in Phase 1; others request changes).

**Phase 2 — two parallel workstreams (need A + B + C):**

- **D. Rendered file view (read path)** *(Opus)*: `PullRequestFilesController`,
  block partial, gutter, change bars, removed strips, thread rendering,
  outdated section, file switcher, system tests for viewing.
- **E. Commenting (write path)** *(Sonnet, precise spec)*: composer,
  `ReviewCommentsController`, `ReviewsController`, `ReviewThreadsController`,
  `ReactionsController`, `MentionablesController`, `MarkdownPreviewsController`,
  Stimulus controllers for composer / mentions / pending tray, integration +
  system tests asserting the exact GitHub payloads.

**Phase 3 — e2e feature specs, integration & polish** *(lead + Sonnet)*:

- **F. End-to-end feature specs** *(Sonnet)*: `test/system/features/*_test.rb`,
  one file per user journey, Capybara + headless Chromium, GitHub stubbed at
  the HTTP layer (WebMock) so every journey also asserts the exact request
  GitHub received: sign in and browse (repos → PRs → overview → file);
  single comment on a changed paragraph (multi-line anchor); comment on a list
  item and a table row; uncommentable block → file-level comment with quote +
  permalink; start a review, add two comments across two files, see the tray
  count survive a reload, submit Approve / Request changes (body required);
  discard a review; reply, edit, delete own comment; react and un-react;
  resolve and unresolve; outdated + LEFT-side + file-level threads placed
  correctly; removed file; renamed file with no patch; @-mention autocomplete
  with keyboard; Markdown preview tab; GitHub 422 shown inline with the text
  kept; rate limit banner; revoked token signs out. Plus an **opt-in live
  tier** `test/e2e/*_test.rb` that runs the write journeys against a real
  scratch repo/PR when `E2E_GITHUB_TOKEN`, `E2E_REPO`, `E2E_PR` are set
  (skipped otherwise; cleans up what it creates), because multi-line range
  rules and the pending-review flow can only be proven against GitHub.
- Error banners, empty states, README, `config/changelog.yml`, a11y pass,
  rubocop/brakeman clean, final lead review.

Ownership boundaries are strict during parallel phases (see AGENTS.md "Stay in
your lane"). Shared surfaces (`routes.rb`, layout, Tailwind theme, `Github::Client`
contract) change only via the owner, with a note in the PR/handoff.

---

## Phase 2 seam: file view (D) ⇄ commenting (E)

D and E build in parallel against this contract. D owns the page; E owns
everything that writes. Neither edits the other's files; ask via message.

**Ids and containers (D renders, E targets with Turbo Streams):**

- Every annotated block, including child blocks (list items, table rows), has a
  wrapper or marker with `id="block_<block.id>"`, `data-block-id`, and the
  gutter button. Top-level blocks are wrapped in `<div class="md-block" …>`.
  For children D post-processes the parent's sanitized HTML (Nokogiri, after
  sanitizing) to add `data-block-id="<child.id>"` to the `<li>`/`<tr>` whose
  `data-sourcepos` starts at the child's `start_line`, and appends an inner
  threads container to it (`<li>` gets a trailing `<div>`, `<tr>` gets a
  following `<tr class="md-thread-row"><td colspan=N>`).
- `id="threads_<block.id>"` — the container where threads for that block
  render (D renders existing threads into it; E appends new ones).
- `id="composer_<block.id>"` — empty slot right after the threads container
  where the composer opens.
- `id="thread_<thread.node_id>"` on each thread card, `id="comment_<comment.node_id>"`
  on each comment, `id="pending_tray"` for the sticky review tray,
  `id="file_threads"` (top of file) and `id="outdated_threads"` (bottom).

**Gutter button (D emits, E's Stimulus controller consumes).** One button per
block with `data-controller`-free plain data attributes so D doesn't depend on
E's JS being loaded:

```erb
<button type="button" class="md-gutter <%= 'md-gutter--muted' unless ab.commentable? %>"
        data-action="composer#open"
        data-block-id="<%= ab.block.id %>"
        data-block-text="<%= ab.block.plain_text.truncate(300) %>"
        data-start-line="<%= ab.block.start_line %>" data-end-line="<%= ab.block.end_line %>"
        data-commentable="<%= ab.commentable? %>"
        data-uncommentable-reason="<%= ab.uncommentable_reason %>"
        data-anchor="<%= ab.anchor&.to_rest&.to_json %>"
        aria-label="Comment on this block">+</button>
```

The whole file view `<main>` carries `data-controller="composer pending-review"`
(E's controllers) with values `data-composer-template-id="composer_template"`,
plus the PR context E needs: `data-composer-owner`, `-repo`, `-number`,
`-path`, `-head-sha`, `-pull-request-node-id`, `-pending-review-node-id`
(blank if none), `-pending-review-id`, `-file-comment-permalink-base`.

**E's partials that D renders:**

- `render "review_comments/composer_template", pull_request:, path:, pending_review:`
  → a `<template id="composer_template">` containing the comment form. E's
  `composer` controller clones it into `composer_<block_id>`, fills hidden
  fields (`path`, `line`, `side`, `start_line`, `start_side`, `subject_type`,
  `block_id`, `commit_id`, `pull_request_node_id`), prefills the body with the
  quote + permalink in file-comment mode (using `Review::FileCommentBody`'s
  format, built client-side from `data-block-text`/lines) and shows the
  uncommentable explanation. Buttons: **Add single comment** and **Start a
  review** / **Add review comment** (label depends on pending review presence,
  toggled live by the `pending-review` controller after the first draft).
- `render "review_comments/thread", thread:, pull_request:, block_id:` → thread
  card with comments, reactions, reply box, resolve/unresolve, edit/delete
  affordances (gated on `viewer_can_*`), outdated/pending badges. E also
  provides `_comment.html.erb` and `_reply_form.html.erb` used inside it.
- `render "reviews/pending_tray", pull_request:, pending_review:, pending_count:`
  → sticky bottom tray (hidden when nothing pending) with Submit review panel
  (body, Approve / Request changes / Comment) and Discard.

**E's controller responses.** All write actions respond to `turbo_stream`
(and redirect back to the file view for plain HTML): create → `append` the
new thread into `threads_<block_id>` + `update composer_<block_id>` to empty +
`replace pending_tray`; reply → `replace thread_<node_id>`; update/destroy →
`replace`/`remove comment_<node_id>` (destroying the last comment removes the
thread); resolve/unresolve → `replace thread_<node_id>`; reactions → `replace
comment_<node_id>`; review submit/discard → redirect to the PR overview with a
flash (the page changes too much to stream). To re-render a thread after a
write, E re-fetches `github.review_threads` and picks the thread by node id
(GitHub is the source of truth; no local state).

**D's page data.** `PullRequestFilesController#show` loads: `pull_request`,
`pull_request_files(head_sha:)`, the file's head content (`file_content` at
`head_sha`) and base content (at `base_sha`, via `base_path`; nil for added
files), `Markdown::Document.parse` for both, `Diff::Patch.parse(file.patch)`,
`review_threads` (once; filtered by path for this file, but the pending count
in the tray counts PENDING comments across all files), `pending_review`, then
`Review::BlockMapper.call`. Threads for `.md` files not currently open are not
shown. Non-Markdown paths redirect to GitHub's file view.

---

## Deliberate v1 deviations

Recorded here so nobody rediscovers them as bugs (see `docs/review-2026-09-19.md`).

- **The block composer requires JavaScript.** Replies, edit, delete, resolve
  and reactions are plain forms and work without JS; the gutter `+` and the
  composer template do not. Prism's core interaction is a rich, in-place
  editor and a no-JS fallback would be a second product; revisit if a real
  need appears.
- **Production caches in `:memory_store`, not Solid Cache.** The deploy target
  is a single small instance (like Sprout/MealMate). With more than one Puma
  worker the per-user cache becomes per-process and the 7-day file-content
  TTLs become advisory. Switch to Solid Cache (`db/cache_schema.rb`,
  `config/cache.yml`) before scaling horizontally.
- **Mermaid and math** render as their `<pre>` fallback (still commentable);
  client-side upgrades are a later step.
