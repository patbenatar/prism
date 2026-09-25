# GitHub API research for a Rails 8.1 rendered-Markdown PR review app

Research date: 2026-09-19. Everything below was checked against `docs.github.com`, `rubygems.org`,
`rubydoc.info`, and GitHub's published GraphQL schema (`https://docs.github.com/public/fpt/schema.docs.graphql`,
downloaded and grepped locally — a copy is at `schema.docs.graphql` next to this file).

Anything I could not verify from primary docs is marked **[UNVERIFIED]** with the evidence I do have.

---

## Decisions & recommendations

| # | Decision | Rationale |
|---|---|---|
| 1 | **Build an OAuth App, not a GitHub App** | A GitHub App user access token "can only access resources in an account where it is installed." The product requirement is "let them pick *a* repository" from everything they can reach. A GitHub App would force an install on every org/user account first, and would silently hide repos. OAuth App tokens see exactly what the user sees. |
| 2 | Scopes: **`repo`, `read:org`, `read:user`** | `repo` is the only scope that grants private-repo read **and** write of PR review comments. `read:org` is needed for org member listing (mentions) and for org repo visibility. `read:user` for the profile. |
| 3 | ~~Do **not** enable OAuth token expiration~~ **SUPERSEDED — production has it enabled, and Prism refreshes.** | This entry assumed the setting was ours to leave alone, and §1.3 below described the mechanism as hypothetical. Neither was true: the production OAuth App expires tokens after 8 hours, which is what was killing webhook deliveries daily. Prism now stores the refresh token and renews through `Github::Credentials`. See `github-auth-longevity.md` §9. |
| 4 | **Octokit 10.0.0 for REST, and `client.post("/graphql", …)` for GraphQL** | Octokit has no GraphQL support, but `Octokit::Connection#post` sends its options hash as the JSON body to any path on `api.github.com`. No second HTTP client, no `graphql-client` gem. |
| 5 | GraphQL is **required**, not optional | Thread grouping with `isResolved` / `isOutdated` / `viewerCanResolve`, and resolve/unresolve, exist **only** in GraphQL. REST gives you `in_reply_to_id` but no resolved state. |
| 6 | **Commentable lines are strictly the lines present in the `patch` hunks** | Confirmed by three independent community reports of `422 "pull_request_review_thread.line must be part of the diff"`. The web UI can comment on expanded context; the REST *and* GraphQL APIs cannot. This is the single biggest constraint on the product. |
| 7 | Render the reviewed `.md` **locally with `commonmarker` using `sourcepos`**, not with `POST /markdown` | You need a source-line → rendered-block mapping to anchor comments. `POST /markdown` returns opaque HTML with no line data. cmark-gfm's `sourcepos` option emits `data-sourcepos="12:1-14:30"` on block elements, which is exactly the anchor you need. |
| 8 | Render **comment bodies** with `POST /markdown` (`mode=gfm`, `context=owner/repo`) | Only GitHub's renderer linkifies `@mentions`, `#123`, and commit SHAs correctly. But it costs 5 secondary-rate-limit points per call — cache rendered bodies keyed by `comment.id + comment.updated_at`. |
| 9 | Use the **two-step pending review flow** for multi-comment reviews | `POST /pulls/{n}/reviews` with no `event` creates a PENDING review; add threads to it; then `POST .../reviews/{id}/events` to submit. This matches GitHub's own "Start a review → Submit review" UX and is the only way to accumulate drafts without persisting them yourself. |
| 10 | Prefer **GraphQL `addPullRequestReviewThread`** over REST for creating comments inside a pending review | REST's `POST /pulls/{n}/comments` has no way to attach to an existing pending review (`in_reply_to` only). `addPullRequestReviewThread` takes `pullRequestReviewId` and is the only clean "add a draft thread to my open pending review" call. |
| 11 | Fall back to **file-level comments** (`subject_type: "file"`) for blocks outside any hunk | Supported by REST (`subject_type`) and GraphQL (`subjectType: FILE`). Not line-anchored, but better than refusing the comment. |

---

## 1. Authentication

### 1.1 OAuth App vs GitHub App

GitHub's own guidance: *"In general, GitHub Apps are preferred to OAuth apps because they use
fine-grained permissions, give more control over which repositories the app can access, and use
short-lived tokens."*
(https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/differences-between-github-apps-and-oauth-apps)

**But that recommendation does not fit this product.** From
https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-with-a-github-app-on-behalf-of-a-user,
a user access token is limited by three things, the third being verbatim:

> "The app can only access resources in an account where it is installed. If your app is only
> installed on a user's personal account, it cannot access resources in an organization that the
> user is a member of unless the app is also installed on that organization."

The app's core flow is "list the repos you can access, pick one." With a GitHub App, that list is
"repos in accounts where a org admin has installed this app" — for most users on day one, empty.
You would need an install-prompt interstitial per org, and org owners often gate app installs.

**Comparison as documented:**

| | OAuth App | GitHub App (user-to-server) |
|---|---|---|
| Acts as | The authenticated user | Bot, or on behalf of a user |
| Repo reach | Everything the user can see | Only accounts where installed |
| Token life | Long-lived by default; expiring optional | 8 h, refresh token 6 months; expiry can be disabled |
| Rate limit | 5,000 req/hr per user | Scales with repo/org size |
| Access model | Coarse scopes (`repo`) | Fine-grained permissions |

**Recommendation: OAuth App.** Document the `repo` scope prominently in your consent screen — it is
broad (full read/write on code) and security-conscious users will ask. If you later need to serve
enterprises that forbid `repo`, ship a GitHub App as a *second* auth option rather than a
replacement.

### 1.2 Exact scopes

From https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps (verbatim):

- **`repo`** — "Grants full access to public and private repositories including read and write access
  to code, commit statuses, repository invitations, collaborators, deployment statuses, and
  repository webhooks."
- **`public_repo`** — "Limits access to public repositories…"
- **`read:org`** — "Read-only access to organization membership, organization projects, and team
  membership."
- **`read:user`** — "Grants access to read a user's profile data."

Mapping to requirements:

| Requirement | Scope |
|---|---|
| List repos incl. private | `repo` |
| Read PRs, files, contents (private) | `repo` |
| Write PR review comments / reviews / reactions | `repo` |
| Resolve review threads (GraphQL) | `repo` — community reports say the mutation checks **Contents: write** on fine-grained tokens, which `repo` covers. **[UNVERIFIED]** for classic scopes; see https://github.com/orgs/community/discussions/204269 |
| Read org members for @-mentions | `read:org` |
| `/user` profile | `read:user` (public data works with no scope) |

`scope=repo,read:org,read:user` — comma-separated in omniauth, space-delimited on the wire.

There is **no narrower scope** that allows writing PR review comments. `public_repo` would work for
public repos only. `repo:status` is explicitly only for commit statuses.

### 1.3 Token lifetime

> **Superseded, and this is the section that was load-bearing and wrong in practice.** Everything
> below is accurate about the API. What it got wrong is the word "if": Prism's **production OAuth
> App has expiration enabled**, so the "if you ever enable it" branch has been the live one since
> before this was written. See `github-auth-longevity.md` §9 for the evidence and for what Prism
> does now. The refresh call documented below is exactly what `Github::Credentials` makes.

OAuth App tokens are long-lived unless you opt into expiration. From
https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps: if expiring
tokens are enabled, the token response also carries `refresh_token`, `expires_in` (28800 = 8 h) and
`refresh_token_expires_in` (15897600 = 6 months).

If you ever enable it (or switch to a GitHub App), the refresh call is:

```
POST https://github.com/login/oauth/access_token
  client_id=...&client_secret=...&grant_type=refresh_token&refresh_token=ghr_...
→ { access_token: "ghu_…", expires_in: 28800,
    refresh_token: "ghr_…", refresh_token_expires_in: 15897600,
    scope: "", token_type: "bearer" }
```
(https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens)

Tokens are also invalidated when the user revokes the app, or after ~1 year of non-use. ~~Treat any
`401` as "token dead, re-authenticate."~~ **A 401 now means "renew, then replay; and only if that
is refused, re-authenticate"** — see `Github::Client#translate_errors`.

### 1.4 The OAuth web flow (what omniauth does for you)

Authorize: `GET https://github.com/login/oauth/authorize` with `client_id`, `redirect_uri`, `scope`,
`state` (CSRF), optional `login`, `allow_signup`, `prompt=select_account`.
Exchange: `POST https://github.com/login/oauth/access_token` with `client_id`, `client_secret`,
`code`, `redirect_uri`.

### 1.5 Rails wiring

Verified gem versions (rubygems.org API, 2026-09-19):

| Gem | Version | Released | Runtime deps |
|---|---|---|---|
| `octokit` | 10.0.0 | 2025-04-24 | `faraday >= 1, < 3`; `sawyer ~> 0.9`; Ruby >= 2.7 |
| `omniauth-github` | 2.0.1 | 2022-09-23 | `omniauth ~> 2.0`; `omniauth-oauth2 ~> 1.8` |
| `omniauth-rails_csrf_protection` | 2.0.1 | 2025-12-10 | `actionpack >= 4.2`; `omniauth ~> 2.0` |

`omniauth-rails_csrf_protection` exists to mitigate CVE-2015-9284 (CSRF on the OmniAuth request
phase). It is mandatory, not optional.

```ruby
# Gemfile
gem "octokit", "~> 10.0"
gem "omniauth", "~> 2.1"
gem "omniauth-github", "~> 2.0"
gem "omniauth-rails_csrf_protection", "~> 2.0"
gem "faraday-retry"          # silences Octokit's Faraday retry warning
gem "commonmarker", "~> 2.0" # local Markdown render with sourcepos
```

```ruby
# config/initializers/omniauth.rb
Rails.application.config.middleware.use OmniAuth::Builder do
  provider :github,
           Rails.application.credentials.dig(:github, :client_id),
           Rails.application.credentials.dig(:github, :client_secret),
           scope: "repo,read:org,read:user"
end

# omniauth 2.x default, stated explicitly for clarity:
OmniAuth.config.allowed_request_methods = %i[post]
OmniAuth.config.silence_get_warning = true
```

```ruby
# config/routes.rb
post  "/auth/github",          as: :github_auth   # link must POST
get   "/auth/github/callback", to: "sessions#create"
post  "/auth/github/callback", to: "sessions#create"
get   "/auth/failure",         to: "sessions#failure"
```

The sign-in link **must** be a POST carrying the Rails authenticity token:

```erb
<%= button_to "Sign in with GitHub", "/auth/github", method: :post, data: { turbo: false } %>
```

```ruby
# app/controllers/sessions_controller.rb
class SessionsController < ApplicationController
  skip_before_action :require_login, only: %i[create failure]

  def create
    auth = request.env["omniauth.auth"]
    user = User.find_or_initialize_by(github_id: auth.uid)
    user.update!(
      login:        auth.info.nickname,
      name:         auth.info.name,
      avatar_url:   auth.info.image,
      access_token: auth.credentials.token,      # encrypted at rest
      token_scopes: auth.credentials.scope.to_s  # verify 'repo' is present
    )
    reset_session
    session[:user_id] = user.id
    redirect_to repositories_path
  end
end
```

### 1.6 Encrypting the token

From https://guides.rubyonrails.org/active_record_encryption.html:

```bash
bin/rails db:encryption:init   # prints the three keys
```

```yaml
# config/credentials.yml.enc
active_record_encryption:
  primary_key: <...>
  deterministic_key: <...>
  key_derivation_salt: <...>
```

```ruby
class User < ApplicationRecord
  encrypts :access_token          # non-deterministic: different ciphertext each time
  # encrypts :github_id, deterministic: true  # only if you must query on it
end
```

Use **non-deterministic** (the default) for the token — you never query by it, and deterministic
encryption leaks equality. Migrate the column as `text` (ciphertext is much longer than the
plaintext `gho_…` token; give yourself ~510 bytes of headroom). Do **not** set
`config.active_record.encryption.support_unencrypted_data = true` in a greenfield app.

---

## 2. Read APIs

### 2.1 List repositories the user can access

`GET /user/repos`
(https://docs.github.com/en/rest/repos/repos)

| Param | Values | Default |
|---|---|---|
| `visibility` | `all`, `public`, `private` | `all` |
| `affiliation` | comma list of `owner`, `collaborator`, `organization_member` | `owner,collaborator,organization_member` |
| `type` | `all`, `owner`, `public`, `private`, `member` | `all` |
| `sort` | `created`, `updated`, `pushed`, `full_name` | `full_name` |
| `direction` | `asc`, `desc` | `asc` for `full_name`, else `desc` |
| `per_page` | max 100 | 30 |
| `since` / `before` | ISO 8601, filters on *updated* time | — |

`affiliation` descriptions verbatim: *"owner: Repositories that are owned by the authenticated user.
collaborator: Repositories that the user has been added to as a collaborator. organization_member:
Repositories that the user has access to through being a member of an organization."*

For "recent push first" use `sort=pushed&direction=desc&per_page=100`. Note `visibility`/`affiliation`
cannot be combined with `type` — pick one style. Fetch 2–3 pages and cache; do **not** auto-paginate
a user with 2,000 repos on a page load.

`GET /orgs/{org}/repos` supports `type` (`all|public|private|forks|sources|member`) and the same
`sort` values, if you want per-org tabs.

**Search:** `GET /search/repositories?q=…` — verbatim rate limit: *"For authenticated requests, you
can make up to 30 requests per minute for all search endpoints except for the Search code endpoint."*
Max 1,000 results per search. Useful `q` for a repo picker filter box:
`q=<term>+user:<login>+fork:true` or `q=<term>+org:<org>`.
(https://docs.github.com/en/rest/search/search)

Practical recommendation: page through `GET /user/repos?sort=pushed` once into a client-side list and
filter in the browser. Fall back to `/search/repositories` only for users with more repos than you
cached, because of the 30/min ceiling.

### 2.2 List pull requests

`GET /repos/{owner}/{repo}/pulls`
(https://docs.github.com/en/rest/pulls/pulls)

| Param | Values | Default |
|---|---|---|
| `state` | `open`, `closed`, `all` | `open` |
| `head` | `user:branch` | — |
| `base` | branch name | — |
| `sort` | `created`, `updated`, `popularity`, `long-running` | `created` |
| `direction` | `asc`, `desc` | `desc` |
| `per_page` | max 100 | 30 |

Fields you need, all present on the list response: `number`, `title`, `user` (login/avatar_url),
`state`, `draft`, `labels[]` (name/color), `updated_at`, `created_at`, `head.sha`, `head.ref`,
`base.sha`, `base.ref`, `html_url`.

Use `sort=updated&direction=desc` for the PR list screen.

### 2.3 Get one PR

`GET /repos/{owner}/{repo}/pulls/{pull_number}`

Adds `mergeable`, `merge_commit_sha`, `additions`, `deletions`, `changed_files`, `commits`.
Verbatim note: *"The value of the mergeable attribute can be true, false, or null. If the value is
null, then GitHub has started a background job to compute the mergeability."* You don't need
mergeability; ignore it rather than polling.

Media type `application/vnd.github.diff` returns the raw unified diff for the whole PR.
**Avoid it** — it returns `406 too_large` past the diff limits (see 2.5) and gives you no
per-file metadata.

### 2.4 List files in a PR

`GET /repos/{owner}/{repo}/pulls/{pull_number}/files`

Verbatim limit: *"Responses include a maximum of 3000 files. The paginated response returns 30 files
per page by default."* Use `per_page=100`.

Response is an array of Diff Entry:

```json
{
  "sha": "bbcd538c8e72b8c175046e27cc8f907076331401",
  "filename": "docs/guide.md",
  "status": "modified",
  "additions": 103,
  "deletions": 21,
  "changes": 124,
  "blob_url":     "https://github.com/o/r/blob/6dcb09b.../docs/guide.md",
  "raw_url":      "https://github.com/o/r/raw/6dcb09b.../docs/guide.md",
  "contents_url": "https://api.github.com/repos/o/r/contents/docs/guide.md?ref=6dcb09b...",
  "patch": "@@ -132,7 +132,7 @@ module Test\n-    puts 'old'\n+    puts 'new'\n     end\n",
  "previous_filename": "docs/old-guide.md"
}
```

`status` ∈ `added`, `removed`, `modified`, `renamed`, `copied`, `changed`, `unchanged`.
`previous_filename` appears only for `renamed`/`copied`.
`patch` is **"included only when present"** — it is omitted for binaries and for files whose diff
exceeds GitHub's limits.

Filter to `.md` / `.markdown` client-side; there is no path filter on this endpoint.

### 2.5 Diff size limits (why `patch` goes missing)

From https://docs.github.com/en/repositories/creating-and-managing-repositories/repository-limits:

| Limit | Value |
|---|---|
| Max files in a single diff | 300 |
| Max total diff you can load | 20,000 lines **or** 1 MB raw |
| Max single-file diff | 20,000 lines **or** 500 KB raw |
| Auto-loaded per file | 400 lines / 20 KB |
| Max renderable files (images, PDF, GeoJSON) per diff | 25 |

*"Some portions of a limited diff may be displayed, but anything exceeding the limit is not shown."*

For Markdown review this is rarely binding — a 500 KB `.md` diff is unusual — but code defensively:
a missing `patch` means **zero commentable lines** for that file, and your UI must degrade to
file-level comments.

### 2.6 Get file contents at a specific SHA

`GET /repos/{owner}/{repo}/contents/{path}?ref={sha}`
(https://docs.github.com/en/rest/repos/contents)

Media types:
- `application/vnd.github.raw+json` → raw bytes of the file (this is what you want for `.md` source)
- `application/vnd.github.html+json` → GitHub-rendered HTML of the markup
- `application/vnd.github.object+json` → consistent object shape
- default JSON → `{ content: <base64>, encoding: "base64", sha, size, name, path, download_url, … }`

Size behaviour, verbatim: for files 1–100 MB *"Only the raw or object custom media types are
supported. Both will work as normal, except that when using the object media type, the content field
will be an empty string and the encoding field will be 'none'."* Over 100 MB, use the Git Trees API.
Markdown files will never hit this.

Fetch head-side with `ref = pr.head.sha`, base-side with `ref = pr.base.sha`. For a `renamed` file the
base-side path is `previous_filename`. For `status == "added"` there is no base side; for
`status == "removed"` there is no head side — expect `404` and handle it.

```ruby
# raw source, no base64 round-trip
source = client.contents(repo, path: file.filename, ref: sha,
                         accept: "application/vnd.github.raw")
```

Tempting alternative: `vnd.github.html+json` gives you GitHub's own rendering of the `.md` file with
one call. **Do not use it for the main view** — it has no source-line mapping, so you cannot anchor
comments. Render locally instead (see §7).

### 2.7 List review comments on a PR

`GET /repos/{owner}/{repo}/pulls/{pull_number}/comments`
(https://docs.github.com/en/rest/pulls/comments)

Params: `sort` (`created`|`updated`, default `created`), `direction` (`asc`|`desc`),
`since` (ISO 8601), `per_page` (max 100), `page`.

Response fields (required unless noted):

```
url, id, node_id, pull_request_review_id (int|null), diff_hunk, path,
commit_id, original_commit_id, user, body, created_at, updated_at,
html_url, pull_request_url, author_association, _links,
position (int, deprecated), original_position (int, deprecated),
in_reply_to_id (int, optional),
line (int), original_line (int), side ("LEFT"|"RIGHT"),
start_line (int|null), original_start_line (int|null),
start_side ("LEFT"|"RIGHT"|null),
subject_type ("line"|"file"),
reactions (Reaction Rollup),
body_html / body_text (media-type dependent)
```

**`position` vs `line` — which to trust.** `position` is a 1-based offset counted down from the
first `@@` hunk header in the *whole file's* patch. The docs state it is closing down
("The position parameter is closing down"). GraphQL marks `position`/`originalPosition` deprecated
with the reason *"We are deprecating comment fields that use diff-relative positioning."*

Rules for this app:

- **Always write `line` + `side`.** Never send `position`.
- **Read `line` + `side`** to place a comment on the *current* head. This is what you anchor to.
- When a comment is **outdated**, `line` and `position` are `null`. `original_line` /
  `original_start_line` / `original_commit_id` still hold, plus `diff_hunk` shows the code it was
  written against. Render outdated threads collapsed with the `diff_hunk` as context — do not try to
  place them in the current file.
- `subject_type == "file"` means the comment has no line at all.
- `start_line`/`start_side` non-null means a multi-line comment spanning `start_line..line`.

Custom media types for rendered bodies are documented (oddly) with a commit-comment prefix:
`application/vnd.github-commitcomment.raw+json`, `.text+json`, `.html+json`, `.full+json`.
**[UNVERIFIED]** whether `body_html` actually comes back on the pulls-comments endpoint with that
header — the naming looks like an OpenAPI copy-paste. Test it; if it fails, use `POST /markdown`
(§2.11) which you need anyway for `@mention` linking in the correct repo context.

### 2.8 Review threads and resolved state — GraphQL only

Confirmed: there is **no REST representation of a review thread or its resolved state**. REST gives
you flat comments plus `in_reply_to_id`. `isResolved` exists only on the GraphQL
`PullRequestReviewThread` object.

Verified field list (`PullRequestReviewThread`, from `docs.github.com/en/graphql/reference/pulls`):

| Field | Type | Description |
|---|---|---|
| `id` | `ID!` | Node ID |
| `isResolved` | `Boolean!` | "Whether this thread has been resolved." |
| `isOutdated` | `Boolean!` | "Indicates whether this thread was outdated by newer changes." |
| `isCollapsed` | `Boolean!` | "Whether or not the thread has been collapsed (resolved)." |
| `resolvedBy` | `User` | "The user who resolved this thread." |
| `path` | `String!` | File path |
| `line` | `Int` | Current line (null when outdated) |
| `originalLine` | `Int` | Line at creation |
| `startLine` / `originalStartLine` | `Int` | Multi-line only |
| `diffSide` | `DiffSide!` | `LEFT` \| `RIGHT` |
| `startDiffSide` | `DiffSide` | Multi-line only |
| `subjectType` | `PullRequestReviewThreadSubjectType!` | `FILE` \| `LINE` |
| `comments` | `PullRequestReviewCommentConnection!` | |
| `viewerCanResolve` / `viewerCanUnresolve` / `viewerCanReply` | `Boolean!` | Drive your UI affordances |
| `pullRequest` | `PullRequest!` | |

`PullRequest.reviewThreads(after: String, before: String, first: Int, last: Int): PullRequestReviewThreadConnection!`

Working query (this is the single call that should drive your whole comment sidebar):

```graphql
query ReviewThreads($owner: String!, $name: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id
      reviewThreads(first: 50, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          isOutdated
          isCollapsed
          resolvedBy { login }
          path
          line
          originalLine
          startLine
          originalStartLine
          diffSide
          startDiffSide
          subjectType
          viewerCanResolve
          viewerCanUnresolve
          viewerCanReply
          comments(first: 100) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              databaseId
              body
              bodyHTML
              createdAt
              publishedAt
              state
              outdated
              isMinimized
              minimizedReason
              diffHunk
              url
              author { login avatarUrl url }
              authorAssociation
              viewerCanUpdate
              viewerCanDelete
              viewerCanReact
              viewerCanMinimize
              replyTo { id }
              reactionGroups {
                content
                viewerHasReacted
                reactors { totalCount }
              }
            }
          }
        }
      }
    }
  }
}
```

Notes:
- `bodyHTML` is GitHub's own rendering with mentions and issue refs already linked — **this removes
  the need to call `POST /markdown` for existing comments entirely.** Only call `/markdown` for
  previewing a body the user is currently typing.
- `databaseId` on a comment is the REST `id`. Keep it: reactions and edit/delete are easier over REST.
- `state` is `PENDING` or `SUBMITTED` — this is how you find the user's unsubmitted draft comments.
- Also fetch `pullRequest.id` here; you need that node ID for `addPullRequestReviewThread`.

`PullRequestReviewComment` full verified field list: `id`, `databaseId`, `body`, `bodyHTML`,
`bodyText`, `author`, `authorAssociation`, `line`, `originalLine`, `startLine`, `originalStartLine`,
`diffHunk`, `outdated`, `state`, `replyTo`, `url`, `createdAt`, `publishedAt`, `minimizedReason`,
`isMinimized`, `viewerCanUpdate`, `viewerCanDelete`, `viewerCanReact`, `viewerCanMinimize`,
`reactionGroups`, `pullRequestReview`, `path`, `position` (deprecated), `originalPosition`
(deprecated), `subjectType`, `commit`, `originalCommit`.

### 2.9 List reviews on a PR

`GET /repos/{owner}/{repo}/pulls/{pull_number}/reviews`
(https://docs.github.com/en/rest/pulls/reviews)

Fields: `id`, `node_id`, `user`, `body`, `state`, `html_url`, `pull_request_url`, `_links`,
`submitted_at` (optional), `commit_id`, `body_html`/`body_text`, `author_association`.

Verbatim: *"Pull request reviews created in the PENDING state are not submitted and therefore do not
include the submitted_at property in the response."* That absence is how you detect the current
user's open pending review. `state` values you will see: `PENDING`, `COMMENTED`, `APPROVED`,
`CHANGES_REQUESTED`, `DISMISSED`.

Related: `GET /repos/{owner}/{repo}/pulls/{pull_number}/reviews/{review_id}/comments` returns just
that review's comments.

### 2.10 People who can be @-mentioned

There is **no public endpoint that reproduces GitHub's own mention autocomplete** (the web UI uses a
private `/suggestions` endpoint). Build the set by union:

| Source | Endpoint | Access needed |
|---|---|---|
| Best: repo collaborators | `GET /repos/{owner}/{repo}/collaborators` | **write, maintain or admin** on the repo |
| Fallback: assignable users | `GET /repos/{owner}/{repo}/assignees` | read access — works for everyone |
| Org members | `GET /orgs/{org}/members` | must be an org member for full list |
| Participants | PR author, reviewers, existing comment authors | free, from data you already have |

Collaborators, required access verbatim: *"The authenticated user must have write, maintain, or admin
privileges on the repository to use this endpoint. For organization-owned repositories, the
authenticated user needs to be a member of the organization."*
Params: `affiliation` (`outside`|`direct`|`all`, default `all`), `permission`
(`pull`|`triage`|`push`|`maintain`|`admin`).
Response: `login`, `id`, `avatar_url`, `name`, `email`, `permissions{pull,push,admin,triage,maintain}`,
`role_name`.
(https://docs.github.com/en/rest/collaborators/collaborators)

Assignees, verbatim: *"Lists the available assignees for issues in a repository."* Only `per_page`/
`page`. Returns Simple User objects. This is the endpoint that works for a read-only reviewer, and it
is a good proxy for "people on this repo."
(https://docs.github.com/en/rest/issues/assignees)

Org members, verbatim: *"List all users who are members of an organization. If the authenticated user
is also a member of this organization then both concealed and public members will be returned."*
Params: `filter` (default `all`), `role` (`all`|`admin`|`member`), `per_page`, `page`. Requires
`read:org`.
(https://docs.github.com/en/rest/orgs/members)

**Recommended strategy:** try `collaborators`; on `403`, fall back to `assignees`; union with
`orgs/{org}/members` when the owner is an org; union with PR participants. Cache per repo for ~10
minutes. Crucially, **GitHub does not validate mentions on write** — an unmatched `@foo` is just
text. So the autocomplete list is a convenience, never a correctness requirement. Ship the fallback
path and don't over-engineer.

### 2.11 Render Markdown with GitHub's renderer

`POST /markdown`
(https://docs.github.com/en/rest/markdown/markdown)

```json
{ "text": "Ping @octocat about #42",
  "mode": "gfm",
  "context": "octo-org/octo-repo" }
```

- `text` (required) — "The Markdown text to render in HTML."
- `mode` — `markdown` (default) or `gfm`.
- `context` — "The repository context to use when creating references in gfm mode." With it, `#42`
  becomes "an HTML link to issue 42 in the octo-org/octo-repo repository."

Returns `200` with an HTML string (`Content-Type: text/html`). `304` on a conditional request.

`POST /markdown/raw` takes `text/plain` / `text/x-markdown` with a 400 KB cap but renders
"plain format like a README.md file" — no GFM, no references. Not useful here.

**Rate-limit reality:** no endpoint-specific limit is documented, but it is a `POST`, so it costs
**5 points** against the 900-points-per-minute-per-endpoint secondary limit. That caps you at
**~180 renders/minute**. Rendering 40 comment bodies on every page load would burn through that fast.

Mitigation, in priority order:
1. Use GraphQL `bodyHTML` for all existing comments (free, comes with the thread query).
2. Use `POST /markdown` only for live preview of the comment being composed, debounced ~400 ms.
3. Cache by `Digest::SHA256.hexdigest(body + context)` in Solid Cache.

Sanitize the returned HTML anyway (`Rails::HTML5::SafeListSanitizer`) — GitHub sanitizes, but you
should not render third-party HTML unfiltered into your own origin.

### 2.12 User profile

`GET /user` → `login`, `id`, `node_id`, `avatar_url`, `name`, `email`, `html_url`, `type`.
Octokit: `client.user`.

---

## 3. Write APIs

### 3.1 Create a single review comment

`POST /repos/{owner}/{repo}/pulls/{pull_number}/comments`

| Field | Req? | Notes |
|---|---|---|
| `body` | ✅ | "The text of the review comment." |
| `commit_id` | ✅ | "The SHA of the commit needing a comment." Use `pr.head.sha`. |
| `path` | ✅ | "The relative path to the file that necessitates a comment." |
| `line` | ✅* | "The line of the blob in the pull request diff that the comment applies to." Required unless `subject_type: "file"`. |
| `side` | — | `LEFT` or `RIGHT`. Defaults to `RIGHT`. |
| `start_line` | — | Required for multi-line. "The first line in the pull request diff that your multi-line comment applies to." |
| `start_side` | — | Required for multi-line. `LEFT` or `RIGHT`. |
| `subject_type` | — | `line` (default) or `file` |
| `position` | — | Deprecated. "The position parameter is closing down." Don't use. |
| `in_reply_to` | — | "The ID of the review comment to reply to." |

Status codes: `201` Created, `403` Forbidden, `422` "Validation failed, or the endpoint has been
spammed."

```json
POST /repos/acme/docs/pulls/42/comments
{
  "body": "This heading should be sentence case.",
  "commit_id": "6dcb09b5b57875f334f61aebed695e2e4193db5e",
  "path": "docs/guide.md",
  "line": 137,
  "side": "RIGHT",
  "start_line": 134,
  "start_side": "RIGHT"
}
```

Semantics: `line` is the line number **in the file on that side** — `RIGHT` = head-side (new file)
line number, `LEFT` = base-side (old file) line number. It is *not* a diff offset. For a multi-line
comment the range is `start_line..line` inclusive.

Verbatim parameter descriptions, which settle how multi-line ranges are expressed:

- `line` — "Required unless using subject_type:file. The line of the blob in the pull request diff
  that the comment applies to. **For a multi-line comment, the last line of the range that your
  comment applies to.**"
- `start_line` — "Required when using multi-line comments unless using in_reply_to. The start_line is
  **the first line in the pull request diff** that your multi-line comment applies to."
- `side` — "In a split diff view, the side of the diff that the pull request's changes appear on. Can
  be LEFT or RIGHT. Use LEFT for deletions that appear in red. Use RIGHT for additions that appear in
  green **or unchanged lines that appear in white and are shown for context**. For a multi-line
  comment, side represents whether **the last line** of the comment range is a deletion or addition."
- `start_side` — "Required when using multi-line comments unless using in_reply_to. The start_side is
  **the starting side** of the diff that the comment applies to. Can be LEFT or RIGHT."

Consequences:

- `side` describes the **last** line of the range; `start_side` describes the **first**. They are
  independent, and nothing in the docs requires them to match. A mixed `LEFT`→`RIGHT` range appears
  expressible. **Do not encode "start_side must equal side" as an invariant.** **[UNVERIFIED
  empirically — probe against a real PR.]**
- `start_line` is documented as "the first line **in the pull request diff**", so both endpoints of
  the range must satisfy the §3.2 constraint. Whether every line *between* them must also be in the
  diff is undocumented. Restricting ranges to a contiguous in-diff run satisfies the strict reading
  either way, so do that.
- `start_line < line` is not documented but is required in practice. **[UNVERIFIED]**

### 3.2 ⚠️ The commentable-line constraint — read this before designing the UI

**A line is commentable if and only if it appears inside one of the file's diff hunks in `patch`.**
That includes added (`+`), deleted (`-`) **and context (` `) lines** — the 3 lines of context on each
side of a change are fully commentable. Anything outside every hunk is not.

The exact failure, reported consistently across three independent community threads:

```
HTTP 422 Unprocessable Entity
{
  "message": "Validation Failed",
  "errors": [
    "Pull request review thread line must be part of the diff",
    "Pull request review thread diff hunk can't be blank"
  ],
  "documentation_url": "https://docs.github.com/rest/pulls/comments#create-a-review-comment-for-a-pull-request"
}
```

Sources:
- https://github.com/orgs/community/discussions/32859 — `"Pull request review thread line must be
  part of the diff and Pull request review thread diff hunk can't be blank"`
- https://github.com/orgs/community/discussions/187218 — `422 Validation Failed
  'pull_request_review_thread.line' is not part of the diff`
- https://github.com/orgs/community/discussions/145141 — open feature request to lift this

**Does GitHub's own web UI allow commenting on expanded-context lines?** Yes. Multiple reporters
state the "Files changed" page lets you expand unchanged context and comment there, on the *same*
PR where the API rejects the identical line. GitHub's user-facing docs on commenting say nothing
about expanded lines either way (I checked
https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/commenting-on-a-pull-request
— it covers hovering a line, shift-click multi-line ranges, and file-level comments, with no mention
of expansion). So: **the web UI uses a private capability the public API does not expose.** The
feature request is open and unanswered. **[UNVERIFIED — no official GitHub statement either way;
treat the API as diff-constrained.]**

GraphQL `addPullRequestReviewThread` is subject to the same validation. There is no workaround.

**Design consequence for this app — this is the central product constraint.** You render the *whole*
`.md` file, but only a subset of its lines can carry a comment. You must:

1. Parse `patch` into `commentable_right` and `commentable_left` line sets (§5).
2. Map each rendered block to its source line range via `data-sourcepos`.
3. A block is commentable iff its line range **intersects** a commentable set. Anchor the comment to
   an intersecting line, not to the block's first line — a heading at line 10 in a hunk covering
   12–20 should anchor at 12.
4. Visually distinguish commentable blocks (comment affordance on hover) from non-commentable ones
   (no affordance, or a muted "outside this PR's diff" tooltip).
5. For a non-commentable block, offer a **file-level comment** (`subject_type: "file"`) whose body
   you prefix with a blockquote of the text the user selected. That preserves the user's intent even
   though GitHub cannot anchor it.
6. Validate client-side before the write. Never let a user type a paragraph and then eat a 422.

Also guard: `commit_id` must be a commit in the PR. Using a stale head SHA after a force-push
produces a 422 as well. Re-fetch the PR before every write burst.

### 3.3 Reply in a thread

`POST /repos/{owner}/{repo}/pulls/{pull_number}/comments/{comment_id}/replies`

Body: `{ "body": "..." }` only. `201` Created, `404` Not found.
`comment_id` must be the **root** comment of the thread (the first comment's REST `id`).

The alternative — `POST .../comments` with `in_reply_to` — is equivalent but needs more fields.
Prefer `/replies`.

For a reply that should join a **pending review** instead of posting immediately, you must use
GraphQL:

```graphql
mutation Reply($reviewId: ID!, $threadId: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {
    pullRequestReviewId: $reviewId,
    pullRequestReviewThreadId: $threadId,
    body: $body
  }) { comment { id databaseId body state } }
}
```
Verified input: `body: String!`, `clientMutationId: String`, `pullRequestReviewId: ID`,
`pullRequestReviewThreadId: ID!`.

### 3.4 Multi-comment pending reviews

**One-shot (all comments known up front):**

```json
POST /repos/{owner}/{repo}/pulls/42/reviews
{
  "commit_id": "6dcb09b...",
  "body": "A few wording nits.",
  "event": "REQUEST_CHANGES",
  "comments": [
    { "path": "docs/guide.md", "line": 137, "side": "RIGHT", "body": "Sentence case please." },
    { "path": "README.md", "start_line": 4, "start_side": "RIGHT",
      "line": 9, "side": "RIGHT", "body": "This list duplicates the one above." }
  ]
}
```

`comments[]` accepts: `path` (required), `body` (required), `line`, `side`, `start_line`,
`start_side`, and the deprecated `position`. **Use `line`/`side`; never `position`.**

`commit_id` verbatim: *"The SHA of the commit that needs a review. Not using the latest commit SHA may
render your review comment outdated… Defaults to the most recent commit in the pull request when you
do not specify a value."* Pass it explicitly so a mid-review push produces a clean 422 rather than
silently misplacing comments.

`event` verbatim: *"By leaving this blank, you set the review action state to PENDING, which means you
will need to submit the pull request review when you are ready."* `body` is required for
`REQUEST_CHANGES` and `COMMENT`; optional for `APPROVE`.

**⚠️ One pending review per user per pull request, and REST cannot append to it.**

A user may hold at most one PENDING review on a PR. A second `POST /pulls/{n}/reviews` while a draft
exists returns `422`. Critically, **there is no REST endpoint that adds a comment to an existing
pending review** — an open feature request asks for exactly this
(https://github.com/orgs/community/discussions/168380). Over REST alone your only options are to
delete and recreate the whole review on every keystroke-committed comment, or to batch every comment
into the single create call and give up incremental drafting.

**GraphQL is the supported incremental path.** `addPullRequestReviewThread` accepts
`pullRequestReviewId`, which attaches a new draft thread to an existing pending review. This is the
single reason the two-step flow below is viable at all.

**Two-step (the flow you want, since the app persists nothing):**

1. `POST /pulls/{n}/reviews` with **no `event`** and no comments → returns a review with
   `state: "PENDING"`. Remember `id` and `node_id`. If this 422s, the user already has a pending
   review — find it and reuse it rather than creating one.
2. Add each draft thread as the user writes it. REST cannot attach a new thread to a specific pending
   review, so use GraphQL:

```graphql
mutation AddDraftThread(
  $reviewId: ID!, $path: String!, $line: Int!, $side: DiffSide!,
  $startLine: Int, $startSide: DiffSide, $body: String!
) {
  addPullRequestReviewThread(input: {
    pullRequestReviewId: $reviewId,
    path: $path, line: $line, side: $side,
    startLine: $startLine, startSide: $startSide,
    body: $body
  }) { thread { id isResolved comments(first:1){ nodes { id databaseId state } } } }
}
```

Verified `AddPullRequestReviewThreadInput` fields: `body: String!`, `clientMutationId: String`,
`line: Int`, `path: String`, `pullRequestId: ID`, `pullRequestReviewId: ID`,
`side: DiffSide = RIGHT`, `startLine: Int`, `startSide: DiffSide = RIGHT`,
`subjectType: PullRequestReviewThreadSubjectType = LINE`.
Pass `pullRequestId` **or** `pullRequestReviewId`, not both: `pullRequestId` alone posts immediately,
`pullRequestReviewId` adds to that pending review.

3. Submit: `POST /pulls/{n}/reviews/{review_id}/events` with
   `{ "event": "APPROVE" | "REQUEST_CHANGES" | "COMMENT", "body": "..." }`.
   Verbatim: *"When you leave this blank, the API returns HTTP 422 (Unrecognizable entity) and sets
   the review action state to PENDING."*

   Or GraphQL `submitPullRequestReview`, verified input: `body: String`, `clientMutationId: String`,
   `event: PullRequestReviewEvent!`, `pullRequestId: ID`, `pullRequestReviewId: ID`.
   `PullRequestReviewEvent` = `APPROVE`, `COMMENT`, `DISMISS`, `REQUEST_CHANGES`.

4. Discard: `DELETE /pulls/{n}/reviews/{review_id}` — verbatim *"Deletes a pull request review that
   has not been submitted. Submitted reviews cannot be deleted."*

Because you persist nothing, **recover the pending review on every page load**: query
`reviewThreads` and look for comments with `state: PENDING`, or list reviews and find one with
`state: "PENDING"` / no `submitted_at`. GitHub itself is your draft store. A user can have at most
one pending review per PR.

Other review endpoints: `GET /pulls/{n}/reviews/{id}`, `PUT /pulls/{n}/reviews/{id}` (body only),
`PUT /pulls/{n}/reviews/{id}/dismissals` with `{ message, event: "DISMISS" }` — the last requires
repo-admin or dismissal rights on protected branches.

### 3.5 Edit and delete your own comment

- `PATCH /repos/{owner}/{repo}/pulls/comments/{comment_id}` body `{ "body": "..." }` → `200`.
- `DELETE /repos/{owner}/{repo}/pulls/comments/{comment_id}` → `204`, or `404`.

Note the path has **no `{pull_number}`**. Gate the UI on GraphQL `viewerCanUpdate` /
`viewerCanDelete` rather than comparing logins — repo admins can edit others' comments, and your
login comparison would wrongly hide the affordance.

Deleting a **pending** comment: use GraphQL `deletePullRequestReviewComment` with
`{ id: ID! }`, or the REST delete with the comment's `databaseId`. **[UNVERIFIED]** whether REST
delete works on an unsubmitted pending comment; the GraphQL mutation is the safer path.

### 3.6 Reactions

(https://docs.github.com/en/rest/reactions/reactions)

- `GET    /repos/{owner}/{repo}/pulls/comments/{comment_id}/reactions` → `200` / `404`
- `POST   /repos/{owner}/{repo}/pulls/comments/{comment_id}/reactions` body `{ "content": "..." }`
  → `201` "Reaction created", `200` "Reaction exists" (idempotent), `422`
- `DELETE /repos/{owner}/{repo}/pulls/comments/{comment_id}/reactions/{reaction_id}` → `204`

`content` ∈ `+1`, `-1`, `laugh`, `confused`, `heart`, `hooray`, `rocket`, `eyes`.

The summary you display comes free with `comment.reactions` (Reaction Rollup) in REST, or
`reactionGroups { content viewerHasReacted reactors { totalCount } }` in GraphQL. **Use
`reactionGroups`** — it carries `viewerHasReacted`, so you can render toggle state without an extra
call; the REST rollup does not tell you whether *you* reacted.

To remove via REST you need the `reaction_id`, which means a `GET` first. GraphQL `removeReaction`
avoids that: `{ subjectId: ID!, content: ReactionContent! }`. GraphQL enum values differ from REST:
`THUMBS_UP`, `THUMBS_DOWN`, `LAUGH`, `HOORAY`, `CONFUSED`, `HEART`, `ROCKET`, `EYES`. Map carefully —
`+1` ↔ `THUMBS_UP`.

**Recommendation: do reactions entirely over GraphQL** (`addReaction` / `removeReaction` with the
comment's node `id`). One call each way, no lookup, correct toggle state.

### 3.7 Resolve / unresolve a thread — GraphQL only

Verified from the published schema:

```graphql
input ResolveReviewThreadInput {
  clientMutationId: String
  resolutionReason: PullRequestReviewThreadResolutionReason  # for Copilot review threads
  threadId: ID!   # PullRequestReviewThread
}
input UnresolveReviewThreadInput {
  clientMutationId: String
  threadId: ID!
}
```
Both payloads return `{ clientMutationId: String, thread: PullRequestReviewThread }`.

```graphql
mutation Resolve($threadId: ID!) {
  resolveReviewThread(input: { threadId: $threadId }) {
    thread { id isResolved isCollapsed resolvedBy { login } }
  }
}
```

Gate on `viewerCanResolve` / `viewerCanUnresolve` from the thread query. Note: only the thread author
or someone with write access can resolve. With a fine-grained token this reportedly requires
**Contents: write**, which is odd but is what users observe
(https://github.com/orgs/community/discussions/204269); the classic `repo` scope covers it.

### 3.8 Rate limits for write bursts

Primary (https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api):
5,000 requests/hour for an authenticated user; 15,000 for GitHub Enterprise Cloud org-affiliated apps.
Headers: `x-ratelimit-limit`, `x-ratelimit-remaining`, `x-ratelimit-used`, `x-ratelimit-reset`
(UTC epoch seconds), `x-ratelimit-resource`, and `retry-after` on secondary breaches.

Secondary limits — all of these matter for this app:

| Limit | Value |
|---|---|
| Concurrent requests | 100 (REST + GraphQL combined) |
| Points per minute per REST endpoint | 900 |
| Points per minute, GraphQL | 2,000 |
| CPU time | 90 s per 60 s wall clock (60 s for GraphQL) |
| **Content-creating requests** | **80 per minute, 500 per hour** |
| OAuth token requests | 2,000/hour |

Point costs: `GET`/`HEAD`/`OPTIONS` = 1; `POST`/`PATCH`/`PUT`/`DELETE` = 5;
GraphQL query = 1; GraphQL with mutations = 5.

**The 500-content-creations-per-hour limit is your real ceiling.** A user submitting a 30-comment
review consumes 30+ creations. Bulk-import or auto-comment features would hit this.

Best practices, verbatim
(https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api):
- *"To avoid exceeding secondary rate limits, you should make requests serially instead of
  concurrently."*
- *"If you are making a large number of POST, PATCH, PUT, or DELETE requests, wait at least one
  second between each request."*
- On `403`/`429`: respect `retry-after`; if `x-ratelimit-remaining` is 0 wait until
  `x-ratelimit-reset`; otherwise wait ≥ 1 minute, then exponential backoff.
- *"Continuing to make requests while you are rate limited may result in the banning of your
  integration."*

Implementation: run all writes through a single Solid Queue job class with `concurrency` limited to 1
per user, sleep 1 s between mutative calls, and surface `Octokit::TooManyRequests` /
`Octokit::AbuseDetected` to the UI as "GitHub is throttling us, retrying in N s."

`GET /rate_limit` costs nothing and returns resources `core`, `search`, `code_search`, `graphql`,
`integration_manifest`, `dependency_snapshots`, `dependency_sbom`,
`actions_runner_registration`, `code_scanning_upload`, `source_import`.

---

## 4. Octokit.rb

**Version 10.0.0** (2025-04-24). Deps: `faraday >= 1, < 3`, `sawyer ~> 0.9`. Ruby >= 2.7.

### Client setup

```ruby
# app/services/github.rb
class Github
  def self.for(user)
    Octokit::Client.new(
      access_token: user.access_token,
      per_page: 100,
      auto_paginate: false          # opt in per call; see below
    )
  end
end
```

Never set `Octokit.configure` globals in a multi-tenant web app — build a client per request from the
current user's token.

### Pagination

README: *"Octokit auto pagination will set the page size to the maximum 100, and seek to not overstep
your rate limit."*

```ruby
client.auto_paginate = true
files = client.pull_request_files("acme/docs", 42)   # walks Link rel="next"
```

Link header shape (https://docs.github.com/en/rest/using-the-rest-api/using-pagination-in-the-rest-api):
`link: <URL>; rel="prev", <URL>; rel="next", <URL>; rel="last", <URL>; rel="first"`.
`per_page` max 100; higher values are silently clamped.

**Use `auto_paginate` selectively.** Turn it on for PR files (bounded at 3,000) and review comments.
Leave it off for `/user/repos` and `/repos/.../pulls` — a big account will otherwise make 50
sequential requests on one page load. Paginate those manually with `client.paginate(url, per_page: 100)
{ |data, last| ... }` and stop early, or just fetch page 1 and offer "load more."

### Raw content / custom media types

```ruby
source = client.contents("acme/docs",
                         path: "docs/guide.md",
                         ref: pr.head.sha,
                         accept: "application/vnd.github.raw")
```
The README's own example: `client.readme 'al3x/sovereign', :accept => 'application/vnd.github.html'`.

### GraphQL

**Octokit.rb has no GraphQL support** — the README does not mention GraphQL at all. But you do not
need another gem. `Octokit::Connection` exposes generic verbs, and for `post`/`put`/`patch` the
options hash is *"Body and header params for request"*, i.e. it becomes the JSON body:

```ruby
# app/services/github/graphql.rb
module Github
  class Graphql
    Error = Class.new(StandardError)

    def initialize(client) = @client = client

    def query(query, **variables)
      res = @client.post("/graphql", { query: query, variables: variables })
      if res.errors.present?
        raise Error, res.errors.map { |e| e.message }.join("; ")
      end
      res.data
    end
  end
end
```

The endpoint is `https://api.github.com/graphql` with `Authorization: bearer TOKEN` — Octokit's
connection already points at `api.github.com` and already sets the auth header, so `client.post("/graphql", …)`
lands exactly right. Body shape is `{"query": "...", "variables": {...}}`
(https://docs.github.com/en/graphql/guides/forming-calls-with-graphql).

One gotcha: **GraphQL returns HTTP 200 even on errors.** Octokit will not raise. You must check
`res.errors` yourself, as above. Sawyer turns the response into a `Sawyer::Resource`, so
`res.data.repository.pullRequest.reviewThreads.nodes` works with camelCase intact.

If you outgrow this, `github/graphql-client` is the next step, but for ~6 queries it is unnecessary
ceremony.

### Error handling

All errors descend from `Octokit::Error` and expose `#response_status`, `#response_headers`,
`#response_body`.

| Class | Status | Handling |
|---|---|---|
| `Octokit::Unauthorized` | 401 | Token revoked/expired. Null the stored token, `reset_session`, redirect to re-auth. |
| `Octokit::Forbidden` | 403 | Could be permissions **or** a secondary rate limit. Check `retry-after` and `x-ratelimit-remaining` to tell them apart. |
| `Octokit::TooManyRequests` | 403/429 | Primary rate limit. Back off to `x-ratelimit-reset`. |
| `Octokit::AbuseDetected` | 403 | Secondary limit. Honour `retry-after`. |
| `Octokit::NotFound` | 404 | Also what you get for a private repo your token can't see — do not render "deleted." |
| `Octokit::UnprocessableEntity` | 422 | **The commentable-line error lands here.** Parse `response_body` for `"must be part of the diff"` and show a specific message. |

```ruby
rescue Octokit::UnprocessableEntity => e
  if e.message.include?("must be part of the diff")
    raise Github::LineNotCommentable, "That line isn't part of this pull request's diff."
  end
  raise
end
```

### Caching / ETags

Verbatim from the docs: *"Making a conditional request does not count against your primary rate limit
if a 304 response is returned and the request was made while correctly authorized with an
Authorization header."* And: *"This makes conditional requests especially useful when you poll an
endpoint, because each 304 Not Modified response is fast and does not use your rate limit."*

Octokit's README recommends `faraday-http-cache`: *"the middleware will store responses in cache based
on ETag fingerprint and serve those back up for future 304 responses for the same resource."*

```ruby
gem "faraday-http-cache"

stack = Faraday::RackBuilder.new do |b|
  b.use Faraday::HttpCache, serializer: Marshal, shared_cache: false, store: Rails.cache
  b.use Octokit::Response::RaiseError
  b.adapter Faraday.default_adapter
end
Octokit.middleware = stack
```

`shared_cache: false` is important — responses are per-user-token and must not leak across users.
Namespace the cache store by user id if you are at all unsure.

Apply this to the PR list, PR files, and comment list. Do **not** conditional-cache writes.
GraphQL does not support ETags; cache those responses yourself with a short TTL.

---

## 5. Diff hunk parsing

### 5.1 Exact format of `patch`

The `patch` string from `/pulls/{n}/files` is the unified diff body for **one file**, with the
`diff --git` / `index` / `---` / `+++` headers **stripped**. It starts at the first `@@`. Lines are
`\n`-separated and there is no trailing newline.

```
@@ -132,7 +132,7 @@ module Test
 context line (leading single space)
-removed line
+added line
 more context
@@ -1000,3 +1000,4 @@
 ...
\ No newline at end of file
```

Hunk header grammar: `@@ -<old_start>[,<old_count>] +<new_start>[,<new_count>] @@[ <section heading>]`
The counts are **optional** — `@@ -1 +1 @@` means count 1 on both sides. The trailing section heading
is free text (often a function name) and must be ignored.

Line prefixes: `' '` context (present on both sides), `'-'` removed (old side only), `'+'` added (new
side only), `'\'` the "no newline at end of file" marker (metadata; consumes no line number).

GitHub uses 3 lines of context per hunk. **Those context lines are commentable** — that is what gives
you a usable comment surface around each change.

### 5.2 Ruby implementation

```ruby
# app/models/diff_hunks.rb
#
# Parses a unified-diff `patch` into the sets of file line numbers that GitHub
# will accept a review comment on, per side.
#
#   hunks = DiffHunks.parse(file.patch)
#   hunks.right          # => Set of new-file line numbers (added + context)
#   hunks.left           # => Set of old-file line numbers (removed + context)
#   hunks.commentable?(137, side: :right)
#
class DiffHunks
  HEADER = /\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/

  Hunk = Struct.new(:old_start, :old_count, :new_start, :new_count, :lines)

  attr_reader :left, :right, :hunks, :right_kind, :left_kind

  def self.parse(patch)
    new(patch)
  end

  def initialize(patch)
    @left  = Set.new   # old-file (LEFT) line numbers
    @right = Set.new   # new-file (RIGHT) line numbers
    @left_kind  = {}   # old_ln => :removed | :context
    @right_kind = {}   # new_ln => :added   | :context
    @hunks = []
    scan(patch) if patch.present?
    freeze_sets
  end

  # No patch at all (binary, too large, pure rename) => nothing is commentable.
  def empty? = @right.empty? && @left.empty?

  def commentable?(line, side: :right)
    (side.to_sym == :left ? @left : @right).include?(line)
  end

  # Given a block spanning source lines a..b, return the best line to anchor a
  # comment to, or nil if the block is entirely outside the diff.
  def anchor_for(range, side: :right)
    set = side.to_sym == :left ? @left : @right
    range.find { |n| set.include?(n) }
  end

  # The largest commentable sub-range inside `range`, for multi-line comments.
  def anchor_range_for(range, side: :right)
    set = side.to_sym == :left ? @left : @right
    hit = range.select { |n| set.include?(n) }
    return nil if hit.empty?
    (hit.first..hit.last)   # GitHub requires a contiguous start_line..line
  end

  private

  def scan(patch)
    old_ln = new_ln = nil
    current = nil

    patch.split("\n", -1).each do |raw|
      if (m = HEADER.match(raw))
        old_ln = m[1].to_i
        new_ln = m[3].to_i
        current = Hunk.new(old_ln, (m[2] || 1).to_i, new_ln, (m[4] || 1).to_i, [])
        @hunks << current
        next
      end

      next if old_ln.nil?                 # junk before the first @@
      next if raw.start_with?("\\")       # "\ No newline at end of file"

      case raw[0]
      when "+"
        @right << new_ln
        @right_kind[new_ln] = :added
        current.lines << [:added, nil, new_ln, raw[1..]]
        new_ln += 1
      when "-"
        @left << old_ln
        @left_kind[old_ln] = :removed
        current.lines << [:removed, old_ln, nil, raw[1..]]
        old_ln += 1
      when " ", nil, ""
        # An empty string is a context line whose content is the empty line.
        @left  << old_ln
        @right << new_ln
        @left_kind[old_ln]  = :context
        @right_kind[new_ln] = :context
        current.lines << [:context, old_ln, new_ln, raw[1..].to_s]
        old_ln += 1
        new_ln += 1
      else
        # Defensive: unknown prefix. Skip without advancing counters.
        next
      end
    end
  end

  def freeze_sets
    @left.freeze; @right.freeze; @left_kind.freeze; @right_kind.freeze
  end
end
```

Pseudocode, for the record:

```
old = new = nil
for each line L in patch.split("\n"):
    if L matches /^@@ -(a)(,b)? \+(c)(,d)? @@/:
        old, new = a, c ; continue
    if old is nil: continue
    if L starts with "\": continue            # no-newline marker
    switch L[0]:
      "+": RIGHT.add(new); new += 1
      "-": LEFT.add(old);  old += 1
      " ": LEFT.add(old); RIGHT.add(new); old += 1; new += 1
      default: continue
```

### 5.3 Edge cases

| Case | `patch` | Commentable |
|---|---|---|
| `status: "added"` | all `+` lines, header `@@ -0,0 +1,N @@` | RIGHT only. LEFT set is empty. No base-side file to fetch — expect 404 on base contents. |
| `status: "removed"` | all `-` lines, header `@@ -1,N +0,0 @@` | LEFT only. No head-side file. Render base content; comments must use `side: "LEFT"`. |
| `status: "renamed"`, content changed | present | Both sides. `previous_filename` gives the base-side path. **Write with the new `filename`**, not the old one. |
| `status: "renamed"`, pure rename | **absent** | Nothing. Only `subject_type: "file"` works. |
| Binary file | **absent** | Nothing. |
| Diff over 20,000 lines / 500 KB | **absent** | Nothing. See §2.5. |
| `status: "unchanged"` | absent | Nothing; the file is in the response but untouched. |
| PR over 3,000 files | file missing entirely | You cannot comment on a file you never received. Surface a warning. |
| Empty-line context | `patch` line is `" "` or `""` | Must count as context. The parser above handles the bare `""` case; a naive `L[0] == " "` check drops it and desynchronises every subsequent line number. |

That last one is the classic bug: some producers strip trailing whitespace, turning a context line for
a blank source line into an empty string. If you skip it, every line number after it in that hunk is
off by one and your comments land on the wrong line. Handle `""` explicitly.

### 5.4 Wiring it to rendered Markdown

```ruby
# 1. source + hunks
file   = client.pull_request_files(repo, number).find { |f| f.filename == path }
hunks  = DiffHunks.parse(file.patch)
source = client.contents(repo, path: path, ref: pr.head.sha,
                         accept: "application/vnd.github.raw")

# 2. render with source positions
html = Commonmarker.to_html(
  source,
  options: { parse: { smart: true }, render: { sourcepos: true, unsafe: false } },
  plugins: { syntax_highlighter: { theme: "base16-ocean.dark" } }
)
# => <h2 data-sourcepos="12:1-12:20">…</h2>

# 3. per block, decide commentability
#    data-sourcepos="12:1-14:30"  =>  lines 12..14
#    range = hunks.anchor_range_for(12..14, side: :right)
#    range.nil?  -> not commentable, offer file-level comment
#    range.size == 1 -> { line: range.first, side: "RIGHT" }
#    else -> { start_line: range.first, start_side: "RIGHT",
#              line: range.last, side: "RIGHT" }
```

`sourcepos` is emitted by cmark-gfm on **block** elements only, not inline ones. That is fine — the
product spec says "line-anchored review comments on rendered blocks."

**[UNVERIFIED]** the exact `commonmarker` 2.x option path for `sourcepos` (`render: { sourcepos: true }`).
Confirm against the gem's docs when you wire it up; the cmark-gfm capability itself is certain.

---

## 6. Endpoint quick reference

| Purpose | Call |
|---|---|
| Profile | `GET /user` |
| Repos | `GET /user/repos?sort=pushed&direction=desc&per_page=100` |
| Org repos | `GET /orgs/{org}/repos?sort=pushed` |
| Repo search | `GET /search/repositories?q=…` (30/min) |
| PR list | `GET /repos/{o}/{r}/pulls?state=all&sort=updated&direction=desc` |
| One PR | `GET /repos/{o}/{r}/pulls/{n}` |
| PR files | `GET /repos/{o}/{r}/pulls/{n}/files?per_page=100` (≤3000) |
| File source | `GET /repos/{o}/{r}/contents/{path}?ref={sha}` + `Accept: application/vnd.github.raw` |
| Review comments | `GET /repos/{o}/{r}/pulls/{n}/comments?per_page=100` |
| Threads + resolved | GraphQL `pullRequest.reviewThreads` |
| Reviews | `GET /repos/{o}/{r}/pulls/{n}/reviews` |
| Mention candidates | `GET /repos/{o}/{r}/collaborators` → fallback `…/assignees` → `GET /orgs/{org}/members` |
| Render markdown | `POST /markdown` `{text, mode:"gfm", context:"o/r"}` |
| New comment | `POST /repos/{o}/{r}/pulls/{n}/comments` |
| Reply | `POST /repos/{o}/{r}/pulls/{n}/comments/{id}/replies` |
| Start pending review | `POST /repos/{o}/{r}/pulls/{n}/reviews` (no `event`) |
| Add draft thread | GraphQL `addPullRequestReviewThread(pullRequestReviewId:)` |
| Submit review | `POST /repos/{o}/{r}/pulls/{n}/reviews/{id}/events` |
| Discard review | `DELETE /repos/{o}/{r}/pulls/{n}/reviews/{id}` |
| Edit comment | `PATCH /repos/{o}/{r}/pulls/comments/{id}` |
| Delete comment | `DELETE /repos/{o}/{r}/pulls/comments/{id}` |
| React | GraphQL `addReaction` / `removeReaction` |
| Resolve thread | GraphQL `resolveReviewThread(threadId:)` |
| Rate limit | `GET /rate_limit` (free) |

---

## 7. Open risks and things to prototype first

1. **The diff constraint is a product risk, not just a technical one.** Build a throwaway script
   against a real PR *before* writing any Rails code: fetch a `.md` file's `patch`, compute the
   commentable set, and see what fraction of the rendered document is actually commentable. On a PR
   that changes three paragraphs of a 500-line doc, that fraction is tiny. If that is unacceptable to
   the product, the answer is to change the view (show the diff with expandable context, like GitHub)
   rather than to fight the API.
2. **Verify `body_html` on pulls comments** with `Accept: application/vnd.github-commitcomment.html+json`.
   If it does not work, GraphQL `bodyHTML` covers you.
3. **Verify `commonmarker` 2.x `sourcepos` option naming.**
4. **Test a force-push mid-review.** Confirm the 422 you get from a stale `commit_id`, and decide the
   UX (re-anchor, or tell the user to reload).
5. **Confirm whether `resolveReviewThread` works with the classic `repo` scope.** Community reports
   concern fine-grained tokens; `repo` should be a superset but prove it.
6. **[UNVERIFIED] `POST /markdown` permission requirement.** A doc fetch suggested "Contents: read"
   for fine-grained tokens, but this endpoint creates and reads nothing repo-specific unless you pass
   `context`. Irrelevant for an OAuth App with `repo`.

---

## Sources verified

**REST**
- https://docs.github.com/en/rest/pulls/comments
- https://docs.github.com/en/rest/pulls/reviews
- https://docs.github.com/en/rest/pulls/pulls
- https://docs.github.com/en/rest/repos/repos
- https://docs.github.com/en/rest/repos/contents
- https://docs.github.com/en/rest/markdown/markdown
- https://docs.github.com/en/rest/reactions/reactions
- https://docs.github.com/en/rest/collaborators/collaborators
- https://docs.github.com/en/rest/issues/assignees
- https://docs.github.com/en/rest/orgs/members
- https://docs.github.com/en/rest/search/search
- https://docs.github.com/en/rest/rate-limit/rate-limit
- https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api
- https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api
- https://docs.github.com/en/rest/using-the-rest-api/using-pagination-in-the-rest-api
- https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens

**GraphQL**
- https://docs.github.com/public/fpt/schema.docs.graphql (downloaded; authoritative for all mutation inputs and enums above)
- https://docs.github.com/en/graphql/reference/pulls
- https://docs.github.com/en/graphql/guides/forming-calls-with-graphql

**Auth**
- https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps
- https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps
- https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/differences-between-github-apps-and-oauth-apps
- https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-with-a-github-app-on-behalf-of-a-user
- https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens

**Limits, Ruby, Rails**
- https://docs.github.com/en/repositories/creating-and-managing-repositories/repository-limits
- https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/commenting-on-a-pull-request
- https://rubygems.org/api/v1/gems/octokit.json
- https://rubygems.org/api/v1/gems/omniauth-github.json
- https://rubygems.org/api/v1/gems/omniauth-rails_csrf_protection.json
- https://github.com/octokit/octokit.rb (README)
- https://www.rubydoc.info/gems/octokit/Octokit/Client/PullRequests
- https://www.rubydoc.info/gems/octokit/Octokit/Client/Reviews
- https://www.rubydoc.info/gems/octokit/Octokit/Connection
- https://guides.rubyonrails.org/active_record_encryption.html

**Community evidence for the diff constraint (no official GitHub statement exists)**
- https://github.com/orgs/community/discussions/32859
- https://github.com/orgs/community/discussions/187218
- https://github.com/orgs/community/discussions/145141
- https://github.com/orgs/community/discussions/204269 (resolveReviewThread permissions)
- https://github.com/orgs/community/discussions/168380 (no REST way to append to a pending review; one pending review per user per PR)
