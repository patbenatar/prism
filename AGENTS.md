# AGENTS.md — Working in this repo

This tells AI coding agents how to work on **Prism**. **Read [`PLAN.md`](PLAN.md)
first** for what the app is, the data model, the routes, and the screen map.

Note on naming: the Ruby constant `Prism` already belongs to Ruby's official
Ruby-language parser gem (a default gem that Rails loads), so the Rails
application module is **`PrismApp`** everywhere in code (`module PrismApp` in
`config/application.rb`, etc.), even though the product, directory, repo, and
compose project are all named "prism".

---

## Running it

Everything is dockerized — there's no host Ruby/Rails dependency.

```bash
docker compose up -d          # app + postgres + css watcher + jobs
docker compose down           # stop everything
docker compose logs app -f    # follow app logs
```

| Service | URL / Port | Purpose |
| --- | --- | --- |
| `app` | http://localhost:**3004** | Rails web (container 3000 → host 3004) |
| `postgres` | localhost:**5436** | Postgres 16 |
| `css` | (none) | `bin/rails tailwindcss:watch` — rebuilds `app/assets/builds/tailwind.css` |
| `jobs` | (none) | `bin/jobs` — Solid Queue worker. Webhook deliveries run here. |
| `tunnel` | http://localhost:**4040** | ngrok, **off by default**: `docker compose --profile tunnel up -d tunnel` gives the dev app a public HTTPS URL so GitHub can deliver webhooks to it, plus a request inspector on 4040. Needs a free `NGROK_AUTHTOKEN`. See `docs/webhooks.md`. |

There is no mailpit/email service — Prism sends no email. Sign-in is GitHub
OAuth only.

Solid Queue's tables live in the **primary** database, so `bin/rails db:prepare`
is the whole setup. Production runs the worker inside Puma
(`SOLID_QUEUE_IN_PUMA`); development runs it as its own container so a web
restart doesn't take the queue with it.

**Containers run as uid `1000:1000`** so bind-mounted files stay owned by the
host user. **Gems are baked into the image** at `/usr/local/bundle` (outside
the `/app` bind mount), so **after editing the Gemfile you must rebuild**:

```bash
docker compose build app && docker compose up -d
```

Run one-off commands with `docker compose exec app <cmd>` (use
`docker compose run --rm --no-deps --entrypoint bash app -c "..."` for
generators that shouldn't touch the DB).

GitHub OAuth needs a GitHub OAuth App (see `.env.example`) with callback
`http://localhost:3004/auth/github/callback`; set `GITHUB_CLIENT_ID` /
`GITHUB_CLIENT_SECRET` in `.env`. Without them, sign-in is unavailable but
nothing else breaks.

**Environment variables.** Copy `.env.example` to `.env` — it carries working
dev values for everything except the two OAuth credentials.

| Variable | Needed for | Notes |
| --- | --- | --- |
| `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` | Signing in | From your GitHub OAuth App. Blank is fine until you want to sign in. |
| `AR_ENCRYPTION_PRIMARY_KEY` | `users.access_token` | Dev values are in `.env.example`. |
| `AR_ENCRYPTION_DETERMINISTIC_KEY` | same | Generate a real set with `docker compose exec app bin/rails db:encryption:init`. |
| `AR_ENCRYPTION_KEY_DERIVATION_SALT` | same | Read from ENV first, falling back to credentials, so CI and Docker work without sharing `config/master.key`. |
| `PRISM_PUBLIC_URL` | Webhooks | The origin GitHub delivers to, and the origin the "review in Prism" link in a pull request description points at. Blank is fine — subscribing is simply unavailable. See `docs/webhooks.md`. |

The GitHub OAuth token is encrypted at rest. Without the three encryption keys
the app still boots, but signing in raises when it tries to store the token.

---

## Testing — the rules

```bash
docker compose exec app bin/rails test          # model + integration (fast)
docker compose exec app bin/rails test:system   # browser-driven (headless Chromium)
```

**Every user-facing feature ships with a Capybara system test** that drives
the real flow through the browser. This is non-negotiable — a system test
that clicks through the UI and asserts the outcome catches the silent
failures (missing partials, broken Turbo Stream targets, a bad GitHub API
response) that unit tests miss.

- New UI feature → at least one system test through the actual flow.
- New controller action → integration test.
- New model logic (scopes, validations, calculations, Markdown/source-position
  mapping) → model test.
- Chromium + chromium-driver are installed in `Dockerfile.dev`.
- **The GitHub API must never be hit for real in tests.** `webmock` is loaded
  in `test/test_helper.rb` with `WebMock.disable_net_connect!(allow_localhost:
  true)` — stub every Octokit call explicitly (`stub_request` or a fixture-
  backed helper).

---

## Architecture conventions

`PLAN.md` is the spec: principles, the `Github::Client` contract, the Markdown
mapping rules, routes, screens, and workstreams. `docs/research/` holds the
verified GitHub API and commonmarker research behind those rules. The short
version:

- **GitHub is the only source of truth.** We persist `users` (and their
  encrypted OAuth token) and nothing else. No comments, drafts, or PR state in
  our database. Pending reviews live on GitHub.
- **`Github::Client` is the only thing that talks to GitHub.** It returns
  `Data.define` value objects from `Github::Types`, never raw Octokit/Sawyer
  resources. Controllers get one via `github` (memoized per request for
  `current_user`). REST via Octokit, GraphQL via `client.post("/graphql", …)`.
- **`Markdown::*`, `Diff::*`, `Review::*` are pure Ruby**, no Rails request
  context, no network. That is where the hard logic lives and where tests are
  exhaustive (golden fixtures under `test/fixtures/markdown/`).
- **Controllers are thin**: authenticate, call the client/service, render.
  Business logic goes in `app/services/<domain>/`.
- **Every GitHub call is made as the signed-in user** with their token, so
  authorization is GitHub's. Never cache GitHub responses without namespacing
  the key by `current_user.id`.
- **Sanitized HTML only.** Rendered Markdown and GitHub `bodyHTML` pass through
  `Markdown::Sanitizer` before `raw`/`html_safe`. Our own wrapper markup and
  data attributes are added *after* sanitizing, never through it.
- **Hotwire, no Node.** Turbo Frames/Streams for in-place updates with an HTML
  fallback, Stimulus controllers under `app/javascript/controllers/`, vendored
  importmap pins only.
- **A Content Security Policy is enforced** in every environment
  (`config/initializers/content_security_policy.rb`). No inline `<script>` and
  no `onclick=` — write a Stimulus controller instead. Inline `style` works
  only via `style-src-attr` and exists for GitHub label colours alone. Adding a
  new asset origin means adding it to the narrowest directive and re-running
  `bin/rails test:system`, which fails on browser-console violations. See
  DESIGN.md §4.
- **Turbo link prefetching is off** (`<meta name="turbo-prefetch" content="false">`
  in the layout). Every page costs GitHub calls against the user's own rate
  limit, so hover-prefetching a list would spend it on pages nobody opened.
  Don't re-enable it globally; opt a single cheap link back in if you ever need
  to. See DESIGN.md §4.
- **Desktop-first reading column** with a comment gutter; still no horizontal
  overflow on a phone. Design tokens and component classes live in
  `app/assets/tailwind/application.css` and are documented in `DESIGN.md`.
- **Stay in your lane** during parallel work: own your files, request changes
  to shared surfaces (`config/routes.rb`, the layout, the Tailwind theme,
  `Github::Client`/`Github::Types`, migrations) from their owner.
- **Parallel test runs**: several agents share one container, so run your
  suite against your own test database:
  `docker compose exec -e TEST_DATABASE=prism_test_<you> app bin/rails db:create db:test:prepare test`
  (the `TEST_DATABASE` env var is honoured by `config/database.yml`).

---

## Working style

- **Follow `PLAN.md` and the design system.** If you need to deviate from the
  data model or routes, note it explicitly rather than silently diverging.
- **Stay in your lane.** During parallel feature work, own your controllers,
  views, and tests; do not edit `config/routes.rb`, the shared layout, the
  Tailwind theme, migrations, or another slice's files without flagging it —
  those are shared surfaces.
- **Ship through a pull request.** Branch, commit, push, open a PR with `gh`,
  wait for CI to pass, then merge. Never commit straight to `main`. CI is where
  the things a local run cannot see get caught — a missing encryption key, a
  race that only shows on a slower machine — so merging before it is green
  throws away the point of having it. Scope commits to one logical change.

---

## Where things live

```
app/
├── controllers/        # thin
├── models/             # AR; associations, scopes, validations
├── services/<domain>/  # optional extracted business logic (GitHub API calls,
│                        # Markdown rendering/source-position mapping)
├── views/
│   ├── shared/         # reusable partials
│   └── layouts/        # the app shell
└── javascript/controllers/   # Stimulus

config/routes.rb        # the routing backbone (see PLAN.md)
db/                      # migrations, schema, seeds
test/{models,integration,system}/
PLAN.md                 # data model, routes, screen map, phases
```
