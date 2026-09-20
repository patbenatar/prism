# Testing Prism

Three tiers, in order of how much they trust GitHub to be real.

| Tier | What | GitHub | Runs by default |
| --- | --- | --- | --- |
| Model / service / integration | `test/models`, `test/services`, `test/integration` | Stubbed (WebMock) | `bin/rails test` |
| System (browser) | `test/system/**/*_test.rb` | Stubbed (WebMock) | `bin/rails test:system` |
| Live e2e (opt-in) | `test/e2e/*_test.rb` | **Real** | Never — see below |

This file documents the second and third tiers in detail. `AGENTS.md` covers
the first.

---

## Tier 1 — end-to-end feature specs (`test/system/features/`)

One file per user journey, each a Capybara + headless Chromium system test
driving the real browser against the real app, with GitHub stubbed at the
HTTP layer (WebMock) — never at the Ruby level, so a broken Turbo Stream
target or a Stimulus controller that never wired up shows up as a failure
here even if every unit test around it is green. Every write journey also
asserts the *exact* request GitHub received: the JSON body of a REST call, or
the `variables` of a GraphQL mutation.

```bash
docker compose exec app bin/rails db:create db:test:prepare   # once
docker compose exec app bin/rails test test/system/features
```

Or, if several agents share the container (see `AGENTS.md` "Parallel test
runs"), against your own test database:

```bash
docker compose exec -e TEST_DATABASE=prism_test_<you> app bin/rails db:create db:test:prepare
docker compose exec -e TEST_DATABASE=prism_test_<you> app bin/rails test test/system/features
```

A single file:

```bash
docker compose exec app bin/rails test test/system/features/pending_review_test.rb
```

### Files and journeys

| File | Journey |
| --- | --- |
| `sign_in_and_browse_test.rb` | Sign in → repos → filter → repo → PR tabs (open/closed) → PR overview (Markdown files lead) → open a file → rendered headings/table/list. Sign out; a signed-out deep link redirects to sign-in and returns you there once you're in. |
| `single_comment_test.rb` | A single comment (posted immediately, not via a review) on a changed paragraph (multi-line anchor), a new list item (single-line, a child block), and a new table row (also a child block). |
| `file_level_comment_test.rb` | A block outside the diff: muted "+", the composer explains why and posts a file-level comment quoting the block, with a permalink into its own lines. |
| `pending_review_test.rb` | Start a review → add a comment (POST create-pending-review, then GraphQL `addPullRequestReviewThread(pullRequestReviewId:)`) → switch files → add a second comment to the same review → tray count survives a reload → submit (Request changes without a body is rejected before it reaches GitHub; with a body, and Approve without a body, both work) → separately, discard a review. |
| `thread_actions_test.rb` | Reply immediately (REST) and into a pending review (GraphQL draft reply); edit and delete your own comment; react and un-react (pill toggles); resolve and unresolve; every affordance hidden when the matching `viewerCan*` is false. |
| `thread_placement_test.rb` | Using the shared fixture that carries one thread of each kind: a RIGHT thread under its block, a LEFT (removed-content) thread with the muted badge, an outdated thread collapsed at the bottom with its original line and diff hunk, a FILE-level thread at the top, and a multi-line PENDING thread counted in the tray. |
| `edge_files_test.rb` | A removed file (base rendered, marked removed, LEFT-only anchors); a renamed file with no patch (nothing commentable); an added file (everything added); a non-Markdown path (redirects to GitHub — asserted without letting a real browser navigate there, see below); an unknown path (404). |
| `mentions_and_preview_test.rb` | `@oc` opens the mention listbox from `/mentionables`, arrow+enter inserts `@octocat `; the Preview tab renders through GitHub's own `/markdown`, and Write keeps the typed text. |
| `errors_test.rb` | A 422 "must be part of the diff" keeps the composer open with the reviewer's text and GitHub's message; a 403 rate limit on page load shows a banner with the reset time; a 401 on any call signs the reviewer out with a flash. |

### Notable patterns

- **`test/support/feature_helpers.rb`** carries what every journey repeats:
  a stable owner/repo/PR cast (`FeatureHelpers::FEATURE_OWNER` etc.),
  `feature_thread`/`feature_comment` builders for the GraphQL `reviewThreads`
  shape, `open_pull_file`, `open_composer_for`, `comment_on_block`, and
  `expect_github_received` (a thin seam over `GithubStubs#assert_github_graphql`
  for a GraphQL operation, or `#github_request_body` for a REST one).
- **Multi-step journeys read from a shared, mutable `state` Hash** rather than
  a fixed sequence of canned responses. `Page#load` and every write re-read
  `reviewThreads`/`.../reviews` an unpredictable number of times (once per
  page load, once more per write, to re-render the tray), so pinning "the
  3rd call returns X" is fragile — off by one, and a later step silently
  reads the wrong snapshot. `stub_feature_reviews_dynamic` /
  `stub_feature_review_threads_dynamic` /
  `stub_feature_create_pending_review_dynamic` /
  `stub_feature_add_thread_dynamic` always answer from `state` as of whenever
  they're asked. **Mutate `state` from inside a dynamic stub's own response
  block (when the request actually arrives), never eagerly before the click
  that triggers it.** An eager `state[:threads] << thread` right before the
  click looks harmless, but if anything reads `state` between that line and
  the click — a file switch is a full Turbo Drive page load, and
  `Page#load_review_state` genuinely re-reads `reviewThreads` — that read
  sees a comment the app hasn't actually created yet, one call too early. A
  real instance of this shipped and was caught when the commenting
  workstream sped up comment creation (no longer re-fetching `reviewThreads`
  on every write) and the composer's own count+1 arithmetic exposed the
  test's premature mutation as a genuine off-by-one. See
  `stub_feature_add_thread_dynamic` and `pending_review_test.rb`.
- **The "+" is `opacity-0` until hover** (DESIGN.md §7). Capybara/Selenium
  treat that as not-visible, so reading a gutter button's data attributes
  *before* hovering needs `visible: :all` (e.g.
  `block.find(".md-add", visible: :all)["data-anchor"]`); after `.hover`, a
  plain `find` works.
- **Never let Capybara actually follow a redirect to `github.com`.** A real
  browser always follows a 3xx — there's no "stop before you get there" in
  Selenium — and this sandbox has no route to the real GitHub, so letting
  Chrome try would hang the run rather than fail one test.
  `edge_files_test.rb`'s non-Markdown redirect assertion instead replays the
  browser's own session cookie over a plain `Net::HTTP` request (never
  through the browser) against Capybara's local server, and asserts the
  `Location` header directly.
- **A `<details>`'s content has no layout box while closed.** The outdated
  section and a resolved thread's body are both closed by default, so
  `assert_selector`'s default `visible: true` will report "no matches" (with
  the unhelpful "Also found ''") until the `<summary>` is clicked open.
- **`accept_confirm { click_on "Discard" }`** is a real native
  `window.confirm()` dialog under Turbo 8's `data-turbo-confirm`, not a
  custom in-page dialog — confirmed by reproducing
  `Selenium::WebDriver::Error::UnexpectedAlertOpenError` when the block is
  omitted. Capybara's `accept_confirm`/`dismiss_confirm` handle it correctly.

### A real bug this tier found (fixed)

`app/views/review_comments/_edit_form.html.erb` had no hidden `thread_id`
field (unlike `_reply_form.html.erb`, which carries one). After editing your
own comment, the re-rendered comment's Delete button inherited a *blank*
`thread_id` (confirmed in `log/test.log`: the follow-up `DELETE` arrived with
`"thread_id"=>""`), so `ReviewCommentsController#render_after_delete` rendered
only the pending tray and never touched the actual thread. Flagged to the
commenting workstream and fixed there (the form now takes a required
`thread_id:` local, threaded through from `_comment.html.erb`, with a
regression test in `review_comments_controller_test.rb`).
`thread_actions_test.rb`'s "editing and deleting your own comment" test
covers the sequence directly again now that it's fixed.

---

## Tier 2 — live GitHub e2e (`test/e2e/`)

Everything above stubs GitHub. This tier is the deliberate exception: it runs
the write journeys against a **real** scratch pull request, because two rules
can only be proven against the real API — the multi-line anchor rule
(`startLine..line` accepted only when every line in the range is genuinely in
the diff) and the pending-review flow end-to-end (GitHub really does permit
exactly one pending review per user per pull request, and
`addPullRequestReviewThread(pullRequestReviewId:)` really drafts rather than
posts).

It drives `Github::Client` and the `Review::*` value objects directly — never
the browser — so a failure here points at the client/anchor logic rather than
at Turbo or Stimulus.

### Running it

Skipped entirely — `bin/rails test` never loads these files at all (see
"Why it can't run by accident" below) — unless all three are set:

```bash
export E2E_GITHUB_TOKEN=ghp_...     # a token with the `repo` scope
export E2E_REPO=your-org/scratch-repo
export E2E_PR=17                    # a PR number in that repo with a real diff

docker compose exec \
  -e E2E_GITHUB_TOKEN -e E2E_REPO -e E2E_PR \
  app bin/rails test test/e2e
```

Use a **scratch repository you control**, not a real project — even though
every write is undone (see below), this tier exercises the actual write path
against your token, and a scratch repo means a slip can't touch anything that
matters. `E2E_PR` needs at least one Markdown file with a real diff (added
*and* modified lines) — the test skips with a clear message if it can't find
a block to anchor to.

### What it does, and what it cleans up

One test opens a pending review, adds a draft thread with a multi-line anchor
and one with a single-line anchor (each computed from the PR's *real* diff by
`Review::AnchorResolver`, not hardcoded), adds a draft reply to the
single-line thread, reads them back via `review_threads` to confirm they are
`PENDING` with the expected lines and sides, then proves a line outside the
diff raises `Github::LineNotCommentable`. Every draft is on a pending review
that gets **deleted** in an `ensure` block — deleting a pending review deletes
every draft thread on it, so nothing is left behind. **It never calls
`submit_review`.**

A second test creates a single file-level comment and deletes it immediately
(`ensure` again).

If a test fails partway through, re-run it — the same `ensure` block still
fires. If you ever suspect something was left behind (a crashed process, a
killed container), open the PR on github.com and delete any pending review
under "Files changed" → your avatar's review banner.

### Why it can't run by accident

Rails' default `bin/rails test` (no path arguments) excludes
`test/{system,dummy,fixtures}/**/*_test.rb` — `test/e2e` isn't in that list,
so without help it *would* load and run these files on every plain
`bin/rails test`. `Rakefile` extends that exclusion glob to include `e2e`
before Minitest resolves the file list (this has to happen in the `Rakefile`,
loaded by the `test:prepare` Rake task, because by the point the exclusion
glob is read, `config/environment.rb` — and so `ENV` from an initializer —
hasn't loaded yet). Passing an explicit path (`bin/rails test test/e2e`)
bypasses the exclusion entirely, which is exactly what the command above
does.

The `skip_unless_e2e_configured!` guard is the second, independent line of
defense: even `bin/rails test test/e2e` with no environment variables set
just skips both tests rather than trying to hit the network.

`test/e2e/e2e_helper.rb` is required directly (`require_relative` from the
test file) rather than living under `test/support/` — `test/support/**` is
auto-required by `test_helper.rb` for every test in the suite, and this
helper (a `User` built from an env var token, real GitHub calls) has no
business loading for the stubbed tiers.
