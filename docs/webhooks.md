# Webhooks — advertising Prism on the pull request

When a pull request in a watched repository contains Markdown Prism can
render, Prism appends a link to its description:

```markdown
<!-- prism:begin -->
---

**[Review 3 Markdown files rendered, in Prism](https://…/acme/docs-site/pulls/42/markdown)** — comment on paragraphs and headings instead of diff lines.
<!-- prism:end -->
```

The horizontal rule makes the block read as a footer rather than as the next
sentence of the author's description. **It sits inside the markers**, so a
retraction takes it with it — a rule written outside them would survive every
removal and pile up. There are tests on exactly that
(`test/services/webhooks/marker_block_test.rb`).

The block carries no attribution line. Deleting it still tells Prism to leave
that pull request alone permanently; that is explained on the subscribe
screen before anyone turns the feature on, rather than restated on every pull
request.

A later push that adds the first renderable Markdown file adds the block; one
that removes the last renderable Markdown file takes it away.

---

## How it hangs together

```
GitHub ──POST /webhooks/github──▶ WebhooksController      (verify · dedupe · 200)
                                        │
                                        ▼  enqueue
                             Webhooks::ProcessDeliveryJob  (Solid Queue, `jobs` service)
                                        │
                                        ▼
                               Webhooks::Announcer         what should be true?
                                        │
                                        ▼
                    Webhooks::AnnouncementTarget::Description   put it there
                                        │
                                        ▼
                             Webhooks::MarkerBlock          the byte-exact splice
```

| Piece | File |
| --- | --- |
| Endpoint | `app/controllers/webhooks_controller.rb` |
| Subscribe screen | `app/controllers/webhook_subscriptions_controller.rb` |
| Job | `app/jobs/webhooks/process_delivery_job.rb` |
| Services | `app/services/webhooks/` |
| Models | `webhook_subscription.rb`, `webhook_delivery.rb`, `pull_request_announcement.rb` |

### Identity

Prism acts **as the person who subscribed the repository**, using their stored
OAuth token. The edit appears on GitHub under their name and avatar, which is
why `/subscriptions` says so above the button rather than below it.

The block itself is unsigned — it names no account. Anyone wanting to know
who made the edit can see it in the pull request's edit history, which is
where GitHub records it either way. What matters is that the person whose
name is on it agreed to that before it happened, and the subscribe screen is
where that happens.

If GitHub later refuses that token, the subscription is **suspended**, not
killed. See "Recovering from a refusal" below — watching a repository is meant
to be something you set up once.

### Recovering from a refusal

`webhook_subscriptions.status` has three values, and the middle one is the
point:

| | |
| --- | --- |
| `active` | GitHub last accepted us. |
| `suspended` | GitHub last refused us, over something a person can fix — almost always a token. **It still acts**: the next delivery retries, and a success clears it. |
| `broken` | Over for good: `MAX_CONSECUTIVE_FAILURES` (20) consecutive refusals. Only removing and re-adding the repository revives it. |

Two things heal a suspension, and neither needs anyone to notice it happened:

1. **The next delivery.** A suspended subscription is still tried. Retrying
   costs nothing extra — the events arrive whether or not we are in a
   position to use them — and a success resets both the status and the
   failure count.
2. **Signing in to Prism.** `User.from_omniauth` revives every suspended
   subscription for that account the moment a sign-in completes. Keyed on the
   sign-in and *not* on the token changing: GitHub hands back the same token
   when the grant is unchanged, and Active Record compares decrypted values
   for dirty tracking, so "the token changed" is false in exactly the case
   where somebody signs in to put things right. Completing the OAuth dance is
   itself proof the token works.

Re-registering a webhook clears it too, for the same reason — GitHub just
accepted a write as that user.

**This used to be a one-way door**, and it was the wrong shape. The reasoning
in the code was "nothing about the failure is transient", which is true of a
deleted repository and false of a token: a token is the one thing the user
*can* fix, and does, usually without ever knowing anything was wrong. In
production two of three subscriptions sat permanently dead while a working
token sat in the database, deliveries logging `ignored: subscription is
broken`. The migration that introduced `suspended` converted every existing
`broken` row to it, because every one of them had got there this way.

A note on the wording, too: Prism used to say "Your GitHub sign-in expired."
OAuth App tokens **do not expire** (`docs/research/github-api.md` §1.3) — one
stops working because it was revoked, or because re-authorizing the app
somewhere else re-issued it. Saying "expired" taught people to expect
short-lived access and to go looking for a setting that does not exist.

### Idempotency

Three separate mechanisms, because they fail differently:

1. **Replays** — `X-GitHub-Delivery` is stored with a unique index. A
   redelivered payload is answered `200` and nothing else happens.
2. **The splice** — `Webhooks::MarkerBlock` replaces exactly the span between
   `<!-- prism:begin -->` and `<!-- prism:end -->` and never touches a byte
   outside it. If the computed body equals the current body, no `PATCH` is
   sent at all.
3. **`pull_request.edited` is ignored** — Prism's own edit produces one, and
   acting on it would loop forever.

Add/remove cycles converge: the separator before the block is chosen from what
the text already ends with, so the description does not gain two newlines
every time. The whole rule set is documented in the comment at the top of
`app/services/webhooks/marker_block.rb`, and `test/services/webhooks/
marker_block_test.rb` is the file to change if you ever want to change it.

### If the author deletes the block

They meant it. `pull_request_announcements.state` goes to `declined` the first
time Prism finds its block missing from a pull request it believed it had
written to, and Prism never writes to that pull request again. This is a
one-way door on purpose. It is also why the block says so in its own text.

### What the link points at

`/:owner/:repo/pulls/:number/markdown`, built with
`repo_pull_markdown_url(owner:, repo:, number:)` in exactly one place,
`app/services/webhooks/review_link.rb`. Agreed with the owner of that screen
and **frozen** — it is written into pull request descriptions that outlive
every refactor, and it is load-bearing on their side too (every "view this
file" link is an anchor into it, the old per-file URL 302s to it), so a
rename fails loudly in both test suites rather than quietly rotting old
links.

That screen answers **200 with an empty state** when a pull request has no
renderable Markdown; it never 404s. That is what makes the small race here
harmless: Prism decides whether to post a link from a file scan taken seconds
earlier, and a file can be renamed out of `.md` between the scan and someone
clicking the link. The reader gets an honest page, not an error.

### Where the link goes — decision: the description, and only the description

`app/services/webhooks/announcement_target.rb` has exactly one
implementation, `AnnouncementTarget::Description`. **That is deliberate, and
the seam is deliberate too. Please don't collapse it back into `Announcer`
as dead abstraction — it is the record of a decision that was made on
purpose.**

A pull request *comment* was considered as the destination and **declined**.
It was attractive for two reasons, both of which are still true and worth
knowing about:

1. **The description edit has a lost-update window we cannot close.** GitHub
   offers no conditional form of `PATCH /repos/{o}/{r}/pulls/{n}` — no
   If-Match, no expected revision. Between reading the body and writing it
   back, an edit the author makes is lost. The window is narrowed as far as
   it goes (the read is uncached and immediately precedes the write, see
   `AnnouncementTarget::Description`) but it cannot be eliminated. A comment
   has no such window, because Prism would own the whole object.
2. **A description is authored prose.** People feel ownership of it in a way
   they do not feel about the comment thread, which is a shared space by
   construction. A comment is additive, collapsible, and unambiguous to
   delete — and it is what most integrations do.

It was declined anyway, with both of those called out: the description is the
better *placement*. It sits at the top, it is visible without scrolling, and
it is the first thing a reviewer sees — which is the entire point of the
feature.

Two consequences follow, and neither is optional:

- **The `declined` door stays exactly as strict.** With the description as
  the destination, it is the only protection against Prism arguing with an
  author. See "If the author deletes the block" above.
- **The read stays uncached and adjacent to the write.** Anything that widens
  the gap — caching the body, batching, moving the read earlier — widens the
  lost-update window.

If this is ever revisited: a comment target implements the same three methods
(`current_content`, `place`, `retract`), reuses `MarkerBlock` completely
unchanged (it recognizes our comment exactly as it recognizes our block),
requires no change to `Announcer` at all, and needs four calls
`Github::Client` does not have yet — list, create, update and delete an issue
comment on the pull request. `PRISM_ANNOUNCEMENT_TARGET` selects between
them. That is roughly an hour of work because the seam exists; it would be a
day without it.

---

## Running it locally

### 1. A public URL

GitHub has to be able to reach the dev app, and `localhost:3004` is not
reachable. **ngrok** runs as a compose service, so there is nothing to
install on the host.

It needs a free account — no card:

1. Sign up at <https://dashboard.ngrok.com/signup>
2. Copy your token from
   <https://dashboard.ngrok.com/get-started/your-authtoken>
3. Put it in `.env` as `NGROK_AUTHTOKEN=…`

**Claim your static domain too**, at
<https://dashboard.ngrok.com/domains>. The free tier includes one, and it is
the difference between a URL that survives restarts and one that does not.
Without it ngrok assigns a random hostname every time the container starts,
and every subscription you registered yesterday is pointing GitHub at an
address that no longer exists.

The tunnel refuses to start, with instructions, if `NGROK_AUTHTOKEN` is
empty. It does not crash-loop, and nothing else in Prism needs the token.

#### No account? `bin/tunnel`

`bin/tunnel` opens a [localhost.run](https://localhost.run) tunnel over plain
SSH. No account, no install, nothing to configure — it prints a public HTTPS
URL and stays up until you stop it.

```bash
bin/tunnel      # prints e.g. https://fabf0f428750e7.lhr.life
```

The catch is the one ngrok's static domain solves: the hostname is **random
every run**, so anything you subscribed against the previous one is pointing
GitHub at an address that no longer resolves. That is precisely the
"Wrong address" state on `/subscriptions`, and re-registering fixes it. Fine
for a one-off test, painful as a daily habit — which is why ngrok is the
documented default and this is the escape hatch.

This path is verified end to end against real GitHub: a subscription
registered through it received `pull_request.opened` for a real pull request,
placed the link in the description, and correctly ignored the
`pull_request.edited` event its own write produced.

### 2. Point Prism at it

```bash
# .env
PRISM_PUBLIC_URL=https://your-name.ngrok-free.app     # your static domain
NGROK_AUTHTOKEN=2abc...
```

```bash
docker compose up -d app jobs                    # picks up the new env
docker compose --profile tunnel up -d tunnel
docker compose logs tunnel                       # the URL, and requests as they land
```

`NGROK_DOMAIN` defaults to `PRISM_PUBLIC_URL`, so setting the one variable
makes the tunnel claim exactly that URL every time. (Set `NGROK_DOMAIN`
separately only if the tunnel should claim something else.) With no static
domain, start the tunnel first, read the assigned URL out of its log, and
paste that into `PRISM_PUBLIC_URL` instead.

`PRISM_PUBLIC_URL` is used for two things: the callback URL registered with
GitHub, and the review link written into pull request descriptions. Nothing
falls back to the request's `Host` header — a callback URL taken from whatever
host header arrived is how you register a hook against someone else's domain.
`config/environments/development.rb` also adds the tunnel hostname to
`config.hosts`, or Rails would answer every tunnelled request with "Blocked
hosts".

Check it end to end:

```bash
curl -sS https://your-name.ngrok-free.app/up
# → 200
```

#### The request inspector

ngrok serves a local inspector at **<http://localhost:4040>** showing every
request that came through the tunnel — full headers and body, including
`X-Hub-Signature-256` and `X-GitHub-Delivery` — and a **Replay** button.

It is the fastest way to answer "did GitHub actually send that, and what
exactly did it send?", and its replay goes over the wire with the original
body, so the signature still verifies. Note that Prism will still treat a
replayed delivery as a replay and do nothing (same GUID — see below); the
inspector is for seeing what arrived, not for forcing reprocessing.

(The compose service writes a one-line ngrok config binding the inspector to
`0.0.0.0:4040`. Its default is localhost, which inside a container means
nothing outside the container could reach it.)

#### Decision: absolute URLs come from `Webhooks::PublicUrl`, not `default_url_options`

**Settled, with the reasoning below. Please don't "fix" it into a global.**

Every other screen in Prism builds paths, because every other screen is
answering a request and can take the host from it. The two URLs here cannot:
the callback is handed to GitHub at registration time, and the review link is
read by people on github.com. Both have to be absolute, and the job that
writes them has no request context at all.

The obvious fix is `default_url_options`. Prism deliberately does not use it,
and the consistency argument for one is weaker than it looks: **nothing else
in Prism builds an absolute URL outside a request.** There is no mailer and no
other job that links out. A global would exist to serve exactly one caller
while silently changing every other `*_url` in development. The three specific
problems:

- It is global. Setting `config.action_controller.default_url_options` in
  development would rewrite *every* `*_url` in the app to the tunnel
  hostname, including ones that should stay on `localhost:3004`.
- It fails badly. An unset `default_url_options` makes a `*_url` helper raise
  `ArgumentError: Missing host to link to!` from inside a job, which is a
  stack trace rather than an explanation.
- It can drift. A global that something else is free to reassign is a poor
  place to keep the one value that decides where a link written into another
  person's pull request points.

Instead `Webhooks::PublicUrl` parses `PRISM_PUBLIC_URL` once and hands the
host, protocol and port to the helper explicitly:

```ruby
Rails.application.routes.url_helpers
     .repo_pull_markdown_url(owner:, repo:, number:, **Webhooks::PublicUrl.url_options)
```

If the variable is missing or unparseable it raises `Webhooks::MissingPublicUrl`,
whose message names the variable and this file, and `/subscriptions` refuses
to register anything rather than pointing GitHub at a URL that cannot work.
The route helper name lives in exactly one place,
`app/services/webhooks/review_link.rb`.

In development, `PRISM_PUBLIC_URL` **must** be the tunnel hostname. A link
built from `localhost:3004` is useless to everyone but you, and it would be
useless permanently — once written, it lives in that pull request's
description after the PR is merged and the branch is deleted.

#### When the tunnel moves: "Wrong address"

If the tunnel's hostname changes — which it does on every restart unless you
claimed the free static domain — a subscription registered yesterday has
GitHub POSTing to a URL that no longer resolves.
**This fails silently in the worst possible way**: GitHub keeps trying, nothing
arrives, and there is nothing in any Prism log to look at, because the request
never reaches us.

So the callback URL that was actually registered is stored on the
subscription (`webhook_subscriptions.callback_url`), and `/subscriptions`
compares it to what `Webhooks::CallbackUrl.current` would produce today. When
they differ the row shows **Wrong address**, names both URLs, says plainly
that nothing is arriving, and offers **Re-register**.

Re-registering `PATCH`es the existing hook (`PATCH /repos/{owner}/{repo}/hooks/{id}`)
rather than deleting and recreating it. That keeps:

- the **secret** — resent in the `PATCH`, because GitHub replaces the whole
  `config` and a cleared secret would mean every later delivery arrives
  unsigned;
- the **hook id** and its delivery history on GitHub;
- the **delivery log**, and — the one that actually matters — every
  `declined` pull request. An author who asked Prism to stop must not be
  forgotten because a hostname changed.

It also clears a `broken` status, since GitHub has just accepted us as this
user on this repository. If GitHub answers 404 (the hook was deleted by hand,
*or* the account is no longer an admin — GitHub gives the same answer for
both) Prism creates a fresh hook, which either works or fails with the admin
message.

Comparison is skipped, rather than guessed at, when `PRISM_PUBLIC_URL` is
unset — that has its own louder warning — or when the row predates this
column.

### 3. The worker

Jobs run in their own container:

```bash
docker compose up -d jobs
docker compose logs jobs -f
```

In production Solid Queue runs inside Puma (`SOLID_QUEUE_IN_PUMA`); in
development it is a separate service so restarting the web server does not
take the queue with it, and so the worker has its own log. Its tables live in
the **primary** database (`db/migrate/*_install_solid_queue_tables.rb`), so
`bin/rails db:prepare` is all the setup there is.

### 4. Register a webhook

Sign in, go to **<http://localhost:3004/subscriptions>**, pick a repository
you have **admin** access to, and press *Watch repository*. Prism will:

- `POST /repos/{owner}/{repo}/hooks` with `events: ["pull_request"]`,
  `content_type: json`, `insecure_ssl: "0"` and a freshly generated
  per-subscription secret;
- store the hook id so unsubscribing can delete it;
- receive GitHub's `ping` immediately (visible in `docker compose logs jobs`
  and as `last_delivery_at` on the row).

The `repo` scope Prism already requests covers repository webhooks — GitHub's
own wording is "read and write access to … repository webhooks" — so no
re-authorization is needed.

**If it fails:**

| What you see | What it means |
| --- | --- |
| "You need admin access to …" | GitHub 404s the hooks endpoints for non-admins, so this is also what a misspelled repository name looks like. |
| "GitHub refused the webhook: … Hook already exists" | Only if the existing hook does *not* point at our callback URL. One that does is adopted and given a new secret. |
| "Prism has no public URL" | `PRISM_PUBLIC_URL` is unset or unparseable. |
| "Wrong address" on an existing row | `PRISM_PUBLIC_URL` has moved since it was registered — usually a restarted tunnel. Press **Re-register**. |

Unsubscribing deletes the hook on GitHub too. If GitHub refuses, the flash
tells you to remove it by hand in **Settings → Webhooks** — Prism will not
silently leave a hook behind without saying so.

### 5. Watch it work

Open a pull request that changes a `.md` file. Within a second or two the
description grows the Prism block. Push a commit that deletes the last `.md`
file and it disappears again.

```bash
docker compose logs jobs -f
docker compose exec app bin/rails runner 'pp WebhookDelivery.recent.limit(5).map { [_1.delivery_id[0,8], _1.action, _1.status, _1.result] }'
```

---

## Replaying a delivery

GitHub keeps every delivery under **Settings → Webhooks → your hook →
Recent Deliveries**, with the full request, the response, and a **Redeliver**
button.

**A redelivery is deliberately a no-op.** GitHub reuses the `X-GitHub-Delivery`
GUID, Prism has already recorded it, and the endpoint answers `200` without
doing anything. That is the replay protection working, not a bug.

To actually reprocess one, drop the recorded delivery first:

```bash
docker compose exec app bin/rails runner \
  'WebhookDelivery.find_by(delivery_id: "PASTE-THE-GUID").destroy'
```

…then press Redeliver.

To re-run only the *work* — no HTTP, no signature — enqueue the job again:

```bash
docker compose exec app bin/rails runner \
  'Webhooks::ProcessDeliveryJob.perform_now(WebhookDelivery.recent.first.id)'
```

And to force a fresh look at a pull request without any delivery at all:

```bash
docker compose exec app bin/rails runner '
  subscription = WebhookSubscription.named("acme", "docs-site").first!
  pp Webhooks::Announcer.new(subscription: subscription, pull_request_number: 42).call
'
```

If a pull request has gone `declined` and you want to undo that (your own test
repository, say):

```bash
docker compose exec app bin/rails runner '
  WebhookSubscription.named("acme", "docs-site").first!
                     .announcement_for(42).update!(state: "absent")
'
```

---

## Testing locally

No tunnel, no GitHub, no network — everything is stubbed.

```bash
docker compose exec -e TEST_DATABASE=prism_test_<you> app \
  bin/rails db:create db:test:prepare test
docker compose exec -e TEST_DATABASE=prism_test_<you> app \
  bin/rails test test/system/webhook_subscriptions_test.rb
```

| What | Where |
| --- | --- |
| Signature: valid, wrong secret, missing, garbage, body swapped after signing | `test/integration/webhooks_test.rb` |
| Replays, ignored actions, malformed bodies, oversized bodies | same |
| Every event shape, idempotency, byte-exact splice, declined, revoked token, rate limits | `test/jobs/webhooks/process_delivery_job_test.rb` |
| The splice on its own, including CRLF and half-deleted markers | `test/services/webhooks/marker_block_test.rb` |
| Constant-time signature check | `test/services/webhooks/signature_verifier_test.rb` |
| Subscribe/unsubscribe including hook deletion | `test/integration/webhook_subscriptions_test.rb`, `test/system/webhook_subscriptions_test.rb` |

Signing a delivery by hand, if you want to poke the endpoint with `curl`:

```bash
SECRET=$(docker compose exec -T app bin/rails runner \
  'print WebhookSubscription.first.secret')
BODY='{"action":"opened","number":42,"pull_request":{"number":42},"repository":{"id":1,"full_name":"acme/docs-site"}}'
SIG="sha256=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')"

curl -sS -i -X POST http://localhost:3004/webhooks/github \
  -H "Content-Type: application/json" \
  -H "X-GitHub-Event: pull_request" \
  -H "X-GitHub-Delivery: $(uuidgen)" \
  -H "X-Hub-Signature-256: $SIG" \
  --data "$BODY"
```

The signature is over the **raw bytes**. Reformatting the JSON, or letting a
tool re-encode it, changes the signature and the endpoint will answer `401` —
which is exactly why `WebhooksController` reads `request.raw_post` and never
the parsed params.

---

## Data

Three tables, all of them Prism's own configuration and Prism's own audit
trail rather than a copy of GitHub's data (PLAN.md principle 1 — the models
say so in their own comments):

| Table | Holds |
| --- | --- |
| `webhook_subscriptions` | which repositories Prism watches, whose token it uses, the encrypted per-hook secret, the GitHub hook id, the callback URL actually registered (so a moved tunnel is visible rather than silent), and its status — `active` / `suspended` / `broken` — with the consecutive-failure count behind it |
| `webhook_deliveries` | one row per accepted delivery: GUID (uniquely indexed — this *is* the replay protection), event, action, pull request number, outcome. No payload. |
| `pull_request_announcements` | per pull request: `present` / `absent` / `declined`. Exists only to tell "we removed our block" from "the author did". |

`webhook_deliveries` is a debugging aid, not an archive; `WebhookDelivery::RETENTION`
is a fortnight and `WebhookDelivery.expired` selects what can go.

## Environment

| Variable | Meaning |
| --- | --- |
| `PRISM_PUBLIC_URL` | The origin GitHub delivers to and the review link points at. Unset means no subscribing; the app is otherwise unaffected. |
| `PRISM_ANNOUNCEMENT_TARGET` | `description` (the only implementation today). |
| `JOB_CONCURRENCY` | Solid Queue worker processes. One is right — GitHub's own advice for writes is serial, not concurrent. |

## Cost per delivery

Two GitHub reads (the pull request's files, and the pull request itself,
fetched uncached so the body we splice into is the body that exists) and one
`PATCH`, and only when the text would actually change. Against the 5,000/hour
primary limit and the 500/hour content-creation limit
(`docs/research/github-api.md` §3.8), a busy repository is nowhere near
either.
