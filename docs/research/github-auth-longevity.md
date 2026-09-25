# GitHub auth longevity — why tokens die, and how to make webhooks always-on

Research date: 2026-09-25. Everything below was checked against `docs.github.com` — in most cases
against the **source Markdown** in `github/docs` (`raw.githubusercontent.com/github/docs/main/content/…`)
rather than the rendered page, because the rendered pages hide version-gated text behind Liquid
conditionals and the per-endpoint permission blocks are generated. Where a fact comes from the
rendered page, the rendered URL is cited.

Anything I could not establish from primary docs is marked **[UNVERIFIED]** with the evidence I do
have. There are four such items and they are all load-bearing, so read them before deciding.

Context: this was written after a production incident. Prism's stored `gho_` token (OAuth App
`Ov23lio4n3yqWIHn3cKD`, scopes `repo, read:org, read:user`) began returning 401. Webhook deliveries
for two repositories failed for ~14 hours; one subscription reached
`WebhookSubscription::MAX_CONSECUTIVE_FAILURES` and is permanently `broken`. Signing in again fixed
it.

---

## Decisions & recommendations

| # | Decision | Rationale |
|---|---|---|
| 1 | **Register a GitHub App *alongside* the existing OAuth App, and use it for webhooks only** | An installation access token is minted from the app's own private key. It needs no human session, no stored user token, and cannot be revoked by anything a user does short of uninstalling. This is the only documented mechanism that removes the person from the loop. |
| 2 | **Do not migrate sign-in and browsing to the GitHub App** (yet) | A GitHub App user access token "can only access resources in an account where it is installed." Prism's product is "pick any repo you can see." Migrating sign-in converts that into "pick any repo in an account where an org owner installed Prism." That is the single biggest risk in this document — §6.2. |
| 3 | **Do not adopt OAuth App expiring tokens + refresh** | They now exist (§2 — this corrects `github-api.md` §1.3 and my own prior assumption), but they solve a problem Prism does not have. The token did not expire; it was revoked. Adding refresh converts a stable credential into an 8-hour one that two processes must race to renew, with single-use refresh tokens. Strictly worse. |
| 4 | **Announcement edits become `prism[bot]`, not the subscriber** | Unavoidable consequence of #1, and arguably an improvement. `docs/webhooks.md` §Identity and the copy on `/subscriptions` both become wrong and must be rewritten. |
| 5 | **Keep every *user-driven* write on the user's OAuth token** | Review comments, reviews, resolves and reactions are the human's, and should stay attributed to the human. Nothing about #1 touches them. |
| 6 | **Before any of this: read the security log** | `https://github.com/settings/security-log?q=action%3Aoauth_authorization` names the actual cause of the incident (§1.9). Every remedy below is sound regardless, but the log turns §1's enumeration into a single answer. |
| 7 | **Revisit `broken` as a terminal state** | Independent of auth. A subscription that GitHub refused 20 times in 14 hours is not evidence that nobody is coming back — it is evidence that deliveries are frequent. §7.3. |

---

## 1. Why a `gho_` OAuth App user token starts returning 401

The authoritative enumeration is
[Token expiration and revocation](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/token-expiration-and-revocation).
Every documented cause is below, with whether it can produce what Prism saw.

### 1.1 The token was pushed to a public repository or public gist

> "If a valid OAuth token, GitHub App token, or personal access token is pushed to a public
> repository or public gist, the token will be automatically revoked."

**Documented. Fits the symptom exactly.** Presents as an immediate, total 401 on every request, with
no warning and no partial degradation. GitHub emails the token owner when this fires.

Worth taking seriously here: Prism's token is decryptable in any process holding the three
`AR_ENCRYPTION_*` keys, and it gets printed by anything that inspects a `User` record without
`filter_parameters` coverage. A token pasted into a log excerpt, an issue, or a gist while debugging
is the commonest way this happens.

### 1.2 Reported to GitHub's credential revocation API by a third party

> "The credential revocation API supports revoking the following token types: … **OAuth App tokens
> with the `gho_` prefix** …"
>
> "When a valid token is submitted to GitHub's credential revocation API, the token will be
> automatically revoked. … To encourage reports and ensure that exposed tokens can be quickly and
> easily revoked, we do not require authentication for the revocation requests submitted through the
> API. As a result, GitHub is unable to provide further information about the source of the reported
> token."

**Documented, and `gho_` is named explicitly.** Fits the symptom. Note the last sentence: if this is
what happened, GitHub will not tell you who reported it.

### 1.3 Revoked by the user

> "You can revoke your authorization of a GitHub App or OAuth app from your account settings which
> will revoke any tokens associated with the app."
>
> "Once an authorization is revoked, any tokens associated with the authorization will be revoked as
> well."

**Documented.** Revokes *every* token for that authorization at once, not just the one Prism holds.
Distinguishable: re-authorizing after a full revocation shows the consent screen again rather than
completing silently. A user who signed in and was *not* asked to re-approve the `repo` scope did not
hit this one.

There is also a bulk version on GitHub Enterprise Cloud — "You can also revoke all your credentials
at once from your account settings" — which behaves the same way from Prism's side.

### 1.4 Revoked by the OAuth App owner

> "The owner of an OAuth app can revoke an account's authorization of their app, this will also
> revoke any tokens associated with the authorization."
>
> "OAuth App owners can also revoke individual tokens associated with an authorization."

**Documented.** Via `DELETE /applications/{client_id}/grant` and `DELETE /applications/{client_id}/token`.
Only relevant if something in Prism (or a person with the client secret) called these. Prism does
not.

### 1.5 The ten-token limit — the one that can kill a *live* token

From `data/reusables/apps/oauth-token-limit.md`, verbatim:

> "There is a limit of ten tokens that are issued per user/application/scope combination, and a rate
> limit of ten tokens created per hour. If an application creates more than ten tokens for the same
> user and the same scopes, GitHub revokes one of the existing tokens with the same
> user/application/scope combination, chosen in this order:
>
> 1. The oldest token that has never been used and that was created more than one minute ago. Tokens
>    created within the last minute are usually protected, so that an application has time to use a
>    token it has just created.
> 1. If there is no such token, but at least one token has been used, the token that was least
>    recently used.
> 1. If no token has ever been used, the oldest token, even if it was created within the last
>    minute."
>
> "Hitting the hourly rate limit will not revoke your oldest token. Instead, it will trigger a
> re-authorization prompt within the browser…"

**Documented, and this is the only documented way an action by the user can silently revoke the
token Prism is actively using.** In practice it is unlikely to have caused this incident: Prism
overwrites `users.access_token` on every sign-in, so the stored token is always the most recently
created one, and webhook deliveries keep it the most recently *used* one. Rule 2 therefore selects
an older, abandoned token. But the margin is thinner than it looks — a user who signs in eleven
times and then does not use Prism for a while, while an older token is exercised by something else,
is inside rule 2's reach.

**This is also the answer to the most important question asked:**

> **Does completing the web flow again revoke the previously issued token for the same user+app?**
>
> **No — not as documented, and the docs point the other way.**
> [Authorizing OAuth apps](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps)
> says "You can create multiple tokens for a user/application/scope combination to create tokens for
> specific use cases," and the ten-token rule above exists precisely because multiple simultaneous
> tokens per user/app/scope are normal. Nothing in the docs says a new authorization invalidates the
> previous token.

**[UNVERIFIED]** — what I could *not* establish is the converse: whether GitHub sometimes returns
the *same* existing token rather than minting a new one when the grant is unchanged. The comment in
`app/models/user.rb#from_omniauth` asserts it does ("GitHub may hand back the same token when the
grant is unchanged"), and that is long-standing folklore, but no page on `docs.github.com` states it
either way. It matters only for dirty-tracking, which `from_omniauth` already handles correctly by
keying the subscription revival on the sign-in rather than on the token changing — so the code is
right regardless of which behaviour is true.

### 1.6 Inactivity

> "GitHub will automatically revoke an OAuth token or personal access token when the token hasn't
> been used in one year."

**Documented. One year, and no shorter period is documented anywhere.** Not applicable: Prism's token
was in use.

### 1.7 Enterprise or organization owner revocation

> "Enterprise owners on GitHub Enterprise Cloud can revoke SSO authorizations or delete credentials
> for individual users, for a specific credential type, or in bulk when responding to security
> incidents. … Organization owners can take the same actions at the organization level. These actions
> are recorded in the audit log, and you will receive an email notification."

**Documented, GHEC only.** Produces exactly this symptom, and — usefully — is the one cause that
sends the user an email.

### 1.8 Causes that are *not* documented, and one that is commonly blamed wrongly

- **Password change or reset.** Not mentioned on the token expiration and revocation page, or
  anywhere else I could find. **[UNVERIFIED]** as a cause; I found no primary source saying it
  revokes OAuth App tokens, and no primary source saying it does not.
- **SAML / SSO session expiry — this does not produce a 401.** GitHub's REST documentation is
  explicit that an unauthorized-for-SSO credential produces *"a `404 Not Found` or a `403 Forbidden`
  error. If you receive a `403 Forbidden` error, the `X-GitHub-SSO` header will include a URL that
  you can follow to authorize your token,"* or, across multiple orgs, a partial result with
  `X-GitHub-SSO: partial-results; organizations=…`
  ([other authentication methods](https://docs.github.com/en/enterprise-cloud@latest/rest/overview/other-authentication-methods)).
  So SSO expiry is a real and recurring cause of webhook failures, but it lands in Prism's
  `Github::Forbidden` branch, not `Github::Unauthorized`. **A 401 rules SAML out.**
- **Organization OAuth App access restrictions.** Same story: a 403, not a 401. Also already handled
  by the `Forbidden` branch in `ProcessDeliveryJob`.
- **Token expiry.** Not applicable — Prism's OAuth App does not have expiring tokens enabled, so the
  token had no expiry to reach (§2).

### 1.9 How to find out which one it actually was

From the same page:

> "When a personal access token, OAuth app token, or GitHub App token expires or is revoked, you may
> see an `oauth_authorization.destroy` action in your security log."

So: **https://github.com/settings/security-log?q=action%3Aoauth_authorization**, filtered to the
window the 401s began. This will distinguish §1.1–§1.5 from each other in a way that no amount of
further reading can. It is a two-minute check and it should be done before any code is written.

---

## 2. Do OAuth Apps support refresh tokens? — **Yes, they do now**

This corrects both the premise of the question and `docs/research/github-api.md` §1.3, which treats
expiring OAuth tokens as a thing to avoid and refresh as a GitHub App feature.

From `content/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps.md`, under the
`oauth-token-expiration` feature gate:

> "### Expiring access tokens
>
> To enforce regular token rotation and reduce the impact of a compromised token, you can configure
> your OAuth app to get access tokens that expire. When your app uses access tokens that expire, you
> will also receive a refresh token with your access token. Both the web application flow and the
> device flow support expiring tokens.
>
> The access token expires after eight hours, and the refresh token expires after six months without
> use."

And `data/features/oauth-token-expiration.yml`, verbatim:

```yaml
# Support for expiring user access tokens and refresh tokens for OAuth apps.
# Shipping to GHES 3.23 and GitHub.com (fpt/ghec).
versions:
  fpt: '*'
  ghec: '*'
  ghes: '>=3.23'
```

`fpt: '*'` — this is live on github.com today, for free accounts included. Three further details
that matter:

- **Per-sign-in opt-in exists.** "To test and gradually roll out support for expiring tokens, you
  can opt in to receive an expiring token and a refresh token for an individual sign-in by
  requesting the `offline_access` scope in addition to your other scopes."
- **Enabling it app-wide does not break existing tokens.** "Enabling this feature does not cause
  existing tokens to expire—they will continue to be long-lived. If you want to switch to expiring
  tokens, have the user sign in again."
- **Refresh tokens are single-use.** "Once you use a refresh token, that refresh token and the old
  access token will no longer work." An invalid or expired one yields `bad_refresh_token`, and "you
  must send the user through the web application flow or device flow again."

**Why Prism should nonetheless not do this.** Refresh solves *expiry*. Nothing in §1 is expiry.
Every cause in §1 kills a refreshed token exactly as dead as an unexpiring one, and the refresh
token along with it. Meanwhile the costs are real and they land on the part of the system that is
already fragile:

- Prism would have two processes that both hold the token — Puma and the Solid Queue worker (which
  is *in* Puma in production, but a separate container in development). Single-use refresh tokens
  mean a concurrent refresh loses the race and destroys a working credential. Doing this safely
  needs a row lock around refresh, retry on `bad_refresh_token`, and a plan for what a background
  job does when it loses.
- It converts a credential that survives indefinitely into one that must be renewed three times a
  day forever, to fix a failure mode that occurred once and was not expiry.

Enabling `offline_access` would be worth revisiting *only* as part of a deliberate rotation policy,
not as a fix for this incident.

---

## 3. GitHub App user-to-server tokens (`ghu_` / `ghr_`)

For completeness, since it is the alternative to §2 if Prism ever migrates sign-in.

| | |
|---|---|
| Access token lifetime | 8 hours by default |
| Refresh token lifetime | 6 months |
| Refresh call | `POST https://github.com/login/oauth/access_token` with `client_id`, `client_secret`, `grant_type=refresh_token`, `refresh_token` |
| Can expiry be disabled? | **Yes** |
| Scope changes on refresh | Not possible — "The scopes on the new access token will match the scopes of the previous token." |

**Expiry can be turned off**, which is the fact the question turns on. From
[Token expiration and revocation](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/token-expiration-and-revocation):

> "User access tokens created by a GitHub App will expire after eight hours by default, and then must
> be regenerated using the included refresh token. **Owners of GitHub Apps can optionally configure
> these tokens to never expire instead, but this is not recommended due to the security
> implications.**"

The setting is "User-to-server token expiration" under
[Activating optional features for GitHub Apps](https://docs.github.com/en/apps/maintaining-github-apps/activating-optional-features-for-github-apps).
GitHub "strongly encourages you to use user access tokens that expire."

**When the refresh token itself expires** (six months *without use* — an actively refreshed app
never gets there), or is otherwise invalid:

> "If your refresh token expires before you use it, you can regenerate a user access token and
> refresh token by sending users through the web application flow or device flow."

The user experience is a sign-in — for Prism, a redirect to `/sign_in` and one click, indistinguishable
from today's session expiry. That is genuinely a non-issue *for the UI*. It is not a fix for
webhooks, because a background job has no user to redirect.

One useful extra: GitHub *tells you* when a user revokes.

> "If a user revokes their authorization of a GitHub App, the app will receive the
> `github_app_authorization` webhook. GitHub Apps cannot unsubscribe from this event. If your app
> receives this webhook, you should stop calling the API on behalf of the user who revoked the token.
> If your app continues to use a revoked access token, it will receive the `401 Bad Credentials`
> error."

OAuth Apps get no such signal — they find out by being refused, which is exactly how Prism found out.

---

## 4. GitHub App installation access tokens — the actual answer for always-on webhooks

### 4.1 Minting one

Two steps, both documented at
[Generating an installation access token](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app):

1. **Sign a JWT with the app's private key.** `alg: RS256`; `iss` = the app's client ID (recommended)
   or app ID; `iat` 60 seconds in the past for clock drift; `exp` "must be no more than 10 minutes
   into the future." GitHub publishes the Ruby version of this verbatim
   ([Generating a JWT](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app)):

   ```ruby
   require 'openssl'
   require 'jwt'
   private_key = OpenSSL::PKey::RSA.new(File.read("YOUR_PATH_TO_PEM"))
   payload = { iat: Time.now.to_i - 60, exp: Time.now.to_i + (10 * 60), iss: "YOUR_CLIENT_ID" }
   jwt = JWT.encode(payload, private_key, "RS256")
   ```

2. **`POST /app/installations/{installation_id}/access_tokens`** with `Authorization: Bearer JWT`.

   > "The installation access token will expire after 1 hour."

   Optional narrowing, both of which Prism should use:

   > "Optionally, you can use the `repositories` or `repository_ids` body parameters to specify
   > individual repositories that the installation access token can access. … You can list up to 500
   > repositories."
   >
   > "Optionally, use the `permissions` body parameter to specify the permissions that the
   > installation access token should have. If `permissions` is not specified, the installation
   > access token will have all of the permissions that were granted to the app."

   The installation id does not have to be looked up on the delivery path: **"If you are responding
   to a webhook event, the webhook payload will include the installation ID."**

Octokit 10 covers both halves — `Octokit::Client.new(bearer_token: jwt)` for the JWT, and
`create_app_installation_access_token(installation, options = {})` (aliased
`create_installation_access_token`) for the exchange
([Octokit::Client::Apps](https://www.rubydoc.info/gems/octokit/Octokit/Client/Apps)). No new HTTP
client; the only new dependency is the `jwt` gem.

### 4.2 Does it work with no user signed in? — **Yes. Categorically.**

This is the crux, and the docs are unambiguous
([Authenticating as a GitHub App installation](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation)):

> "Once your GitHub App is installed on an account, you can make it authenticate as an app
> installation for API requests. This allows the app to access resources owned by that installation,
> as long as the app was granted the necessary repository access and permissions. **API requests made
> by an app installation are attributed to the app.**"
>
> "Requests made with an installation access token are sometimes called 'server-to-server' requests."

And, from the OAuth/GitHub App comparison table
([Differences between GitHub Apps and OAuth apps](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/differences-between-github-apps-and-oauth-apps)):

> "A GitHub App can request an installation access token by using a private key with a JSON web token
> format **out-of-band**. | An OAuth app requires **interactive authentication by a user** to receive a
> user access token."

The inputs are the app's private key, the app id, and an installation id that arrives in the webhook
payload. No session, no stored user token, nothing a user can revoke short of uninstalling the app.
Every failure mode in §1 disappears from the webhook path.

### 4.3 Rate limits

From [Rate limits for the REST API](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api):

- Installation access token: **5,000 requests/hour minimum**, scaling — "Installations that have more
  than 20 repositories receive another 50 requests per hour for each repository. Installations that
  are on an organization that have more than 20 users receive another 50 requests per hour for each
  user. The rate limit cannot increase beyond 12,500 requests per hour."
- **15,000/hour** if the installation is on a GitHub Enterprise Cloud organization.
- For comparison, today: OAuth App tokens "use the user's rate limit of 5,000 requests per hour" —
  and, critically, Prism's webhook jobs currently *share* that budget with the same person's
  interactive browsing. An installation token gives webhooks their own pool. That alone is a
  meaningful win, given `AGENTS.md` already disables Turbo prefetch to protect this budget.

### 4.4 Permissions needed — all repository-level, no organization permissions

Taken verbatim from the "Fine-grained access tokens for …" blocks on the rendered REST reference
(these are generated from GitHub's internal permission data and are the authoritative statement per
endpoint). Every one of them lists "GitHub App installation access tokens" among the accepted token
types.

| What Prism's webhook path does | Endpoint | Required permission |
|---|---|---|
| Read the pull request | `GET /repos/{o}/{r}/pulls/{n}` | at least one of **Pull requests (read)** *or* **Contents (read)** |
| List its files | `GET /repos/{o}/{r}/pulls/{n}/files` | **Pull requests (read)** |
| Read file contents at a SHA | `GET /repos/{o}/{r}/contents/{path}` | **Contents (read)** |
| **Edit the pull request body** | `PATCH /repos/{o}/{r}/pulls/{n}` | **Pull requests (write)** |
| Receive the `pull_request` event | — | **Pull requests (read)** |

The last row is from [Webhook events and payloads](https://docs.github.com/en/webhooks/webhook-events-and-payloads#pull_request):
"To subscribe to this event, a GitHub App must have at least read-level access for the 'Pull
requests' repository permission."

So the whole webhook feature needs exactly **Pull requests: write** and **Contents: read**, plus the
implicit Metadata: read. Nothing organization-scoped. Compared with `repo` — "full access to public
and private repositories including read and write access to code" — this is a dramatic narrowing,
and a much easier consent screen to defend.

Note also what *drops out*: Prism currently creates and deletes repository webhooks itself, which on
a GitHub App would need **Webhooks (write)**. It does not need it, because GitHub App webhooks are
built in — see §6.4.

---

## 5. Attribution consequences

### 5.1 With an installation token: `prism[bot]`

Verbatim, from the comparison table:

> "An installation token identifies the app as a **GitHub App bot account, such as @jenkins[bot]**. |
> A user access token identifies the app as **the user who signed into the app, such as @octocat**."

So the "review in Prism" block would be spliced into the description by `prism[bot]`, and the pull
request's edit history would name the bot rather than the subscriber.

**What changes for the user**, concretely:

- `docs/webhooks.md` §Identity is wrong end to end. "Prism acts **as the person who subscribed the
  repository**, using their stored OAuth token. The edit appears on GitHub under their name and
  avatar, which is why `/subscriptions` says so above the button rather than below it" — all of that
  has to be rewritten, and the copy above the subscribe button with it.
- It is a straightforward improvement on the point that copy exists to address. Today the block is
  unsigned but the edit is under a human's name, which is a slight mismatch: the reader sees a
  colleague apparently editing someone else's PR description. `prism[bot]` says what is actually
  happening. The consent conversation gets *easier*, not harder — nobody's name is being borrowed.
- It removes a coupling that is currently invisible and surprising: subscribing a repository today
  silently makes future automated edits appear under your name, indefinitely, including after you
  stop using Prism.

### 5.2 With a user token: still the human, with a badge

A GitHub App can absolutely still write as the person when a person is driving
([Authenticating on behalf of a user](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-with-a-github-app-on-behalf-of-a-user)):

> "API requests made by an app on behalf of a user will be attributed to that user. For example, if
> your app posts a comment on behalf of a user, the GitHub UI will show the user's avatar photo along
> with **the app's identicon badge** as the author of the issue."
>
> "Similarly, if the request triggers a corresponding entry in the audit logs and security logs, the
> logs will list the user as the actor but will state that the `programmatic_access_type` is 'GitHub
> App user-to-server token'."

So review comments, reviews, resolves and reactions keep the human's name and avatar; the only
visible change is a small app badge overlaid on the avatar. This is what every GitHub-integrated
review tool looks like and is not a regression.

Under the recommended hybrid (§7.1) this question does not even arise — user-driven writes keep
going out on the OAuth token and look exactly as they do today.

---

## 6. Migration cost and risk, OAuth App → GitHub App

### 6.1 Existing sessions and stored tokens

Nothing breaks and nothing migrates. The OAuth App and its tokens are untouched by registering a
GitHub App; they keep working until separately revoked. But there is no automatic path across
([Migrating OAuth apps to GitHub Apps](https://docs.github.com/en/apps/creating-github-apps/about-creating-github-apps/migrating-oauth-apps-to-github-apps)):

> "**There is not a way to automatically migrate your users.** Each user must install and/or authorize
> your GitHub App on their own."

And, if the OAuth App is eventually retired:

> "Once your users have migrated to your new GitHub App, you should delete your old OAuth app. …
> **This action will also revoke all of the OAuth app's remaining authorizations.**"

For Prism that means: deleting the OAuth App signs out every user who has not moved. Sequencing
matters, and `users.access_token` becomes dead weight for anyone who does not return.

### 6.2 **The product risk: does "browse any repo I can see" survive?**

**Partly, and only for public repositories. For private repositories it does not.** This is the
finding that should drive the decision.

The constraint is stated three times in GitHub's docs, most explicitly at
[Authenticating on behalf of a user](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-with-a-github-app-on-behalf-of-a-user):

> "When operating on behalf of a user, your app's access is limited to ensure secure and appropriate
> access:
>
> * The app can only access resources that the user has access to. …
> * The app can only access resources that it has permission to access. …
> * **The app can only access resources in an account where it is installed. If your app is only
>   installed on a user's personal account, it cannot access resources in an organization that the
>   user is a member of unless the app is also installed on that organization.**"

And, restated as an intersection at
[Generating a user access token](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app):

> "A user access token can only access resources that **both** the user and app can access. For
> example, if an app is granted access to repository `A` and `B`, and the user can access repository
> `B` and `C`, the user access token can access repository `B` but not `A` or `C`."

Three mitigating facts, none of which rescue the private case:

- **Sign-in itself does not require installation.** "An app does not need to be installed in order for
  a user to authorize the app." So authentication works on day one for everybody.
- **Public repositories are readable without installation.** From
  [Choosing permissions](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app):
  "Although GitHub Apps don't have any permissions by default, they do have **implicit permissions to
  read public resources when acting on behalf of a user.**" A user access token "can make requests to
  the REST API and the GraphQL API to read public resources."
- **There are purpose-built discovery endpoints**: `GET /user/installations` ("List app installations
  accessible to the user access token" — no permissions required) and
  `GET /user/installations/{installation_id}/repositories` ("List repositories accessible to the user
  access token" — Metadata: read). These are what the repo picker would become.

**[UNVERIFIED], and it is the single thing worth prototyping before committing:** what
`GET /user/repos` — the call behind Prism's repo picker today — actually returns for a GitHub App
user access token. The REST reference says it accepts "GitHub App user access tokens" with "Metadata
(read)"; the account-scope rule above says results must be confined to installed accounts; and no
page states how those two interact for a *listing* endpoint (silently filtered, error, or public-only).
I could not resolve this from primary sources. It is a ten-minute experiment against a throwaway
GitHub App and it determines whether the picker needs rewriting around `/user/installations`.

**And the operational reality behind all of it:** from the comparison table, "You must be an
organization owner or have admin permissions in a repository to install a GitHub App on an
organization." So for any user whose work lives in an org they do not administer, the private-repo
list on day one is empty until an owner acts. `docs/research/github-api.md` §1.1 already called this
out as the reason to build an OAuth App, and nothing found in this round changes that judgement.
Decision #1 in that document remains correct **for the browsing product**; it is simply the wrong
tool for a background job.

### 6.3 Can a GitHub App still do everything Prism's UI does today, as the user?

**Yes.** Every endpoint Prism writes through accepts GitHub App user access tokens. From the
generated permission blocks on the REST reference:

| Prism UI action | Endpoint | Permission | Accepts user tokens |
|---|---|---|---|
| Create a review comment | `POST /pulls/{n}/comments` | Pull requests (write) | yes |
| Reply in a thread | `POST /pulls/comments/{id}/replies` | Pull requests (write) | yes |
| Create a pending review | `POST /pulls/{n}/reviews` | Pull requests (write) | yes |
| Submit a review | `POST /pulls/{n}/reviews/{id}/events` | Pull requests (write) | yes |
| Edit / delete own comment | `PATCH`/`DELETE /pulls/comments/{id}` | Pull requests (write) | yes |
| React to a review comment | `POST /pulls/comments/{id}/reactions` | Pull requests (write) | yes |
| List reviews / comments / files | various `GET` | Pull requests (read) | yes |

**[UNVERIFIED] — GraphQL.** `resolveReviewThread` / `unresolveReviewThread` and the thread queries
carrying `isResolved` / `isOutdated` / `viewerCanResolve` are GraphQL-only (`github-api.md` §2.8,
§3.7), and GitHub declines to document GraphQL permissions at all. Verbatim, from the migration
guide: **"Permissions are not currently documented for GraphQL requests."** And from Choosing
permissions: "For GraphQL requests, you should test your app to ensure that it has the required
permissions for the GraphQL queries and mutations that you want to make. If your app makes a GraphQL
API query or mutation with insufficient permissions, the API will return a `401` response."

This compounds an existing open risk — `github-api.md` §7.5 already lists "Confirm whether
`resolveReviewThread` works with the classic `repo` scope" as unproven. Under a GitHub App it would
need proving again against fine-grained permissions, with no documentation to predict the answer.
Community evidence (github/community#204269, already cited in `github-api.md`) points at Contents:
write, which is a *broader* permission than the Pull requests: write the rest of the UI needs — an
unpleasant surprise if true, since it would put code-write permission back on the consent screen.

### 6.4 What gets *better*

Worth stating plainly, because §6.2 is otherwise one-sided.

> "Unlike webhooks for OAuth apps, which you must configure via the API for each repository or
> organization, **webhooks are built into GitHub Apps**. When you register your GitHub App, you can
> select the webhook events that you want to receive."

One webhook URL, one secret, configured once on the app registration. That deletes a surprising
amount of Prism: `webhook_subscriptions.hook_id`, the per-subscription `secret`, the creation and
deletion calls against `/repos/{o}/{r}/hooks`, and the `callback_stale?` machinery that exists
because the registered callback URL can drift from `PRISM_PUBLIC_URL`. Subscribing stops being "ask
GitHub to create a hook with this person's `repo` scope" and becomes "install Prism here" — which is
also the moment GitHub itself asks for consent, in its own UI, with the permissions listed.

The migration guide also documents the cleanup path if both exist at once, which is exactly Prism's
hybrid situation:

> "When a user installs your GitHub App and grants access to a repository, you should remove any
> webhooks for your old OAuth app. If your new GitHub App and your old OAuth app respond to webhooks
> for the same event, the user may observe **duplicate behavior**. To remove repository webhooks, you
> can listen for the `installation_repositories` webhook with the `added` action."

Duplicate `pull_request` deliveries producing two attempts to splice the same marker block is a real
hazard during a hybrid rollout. `Webhooks::MarkerBlock` is idempotent by construction, and
`pull_request_announcements` dedupes, so the blast radius is wasted calls rather than a mangled
description — but the cleanup listener above is the documented answer and should be built, not
skipped.

---

## 7. Is there a way to keep the OAuth App and still have always-on webhooks?

**No. Not honestly, and not in a way that would survive the incident that prompted this.**

The OAuth App model has exactly one credential type: a token issued to a human, bound to that
human's grant, revocable by seven documented mechanisms (§1), several of which are outside both
Prism's and the user's control. There is no server-to-server credential for an OAuth App — that is
precisely the line the comparison table draws ("out-of-band" vs "interactive authentication by a
user"). Anything built on the OAuth App is one revocation away from the same 14-hour outage. What
follows are mitigations, and they should be understood as reducing the frequency and the blast
radius, not as satisfying the requirement.

### 7.1 Mitigations worth doing anyway

1. **Fall back across subscribers.** `webhook_subscriptions` currently has one `user_id`. If more
   than one person in a repo has signed into Prism, a refused delivery could retry as another of
   them. This turns a single revoked token from an outage into a blip, and it is cheap. It does not
   help the common case of one person per repo — which is Prism's actual case today.
2. **Alert on the first refusal, not the twentieth.** A 401 on a webhook delivery is currently
   invisible to everyone until someone opens `/subscriptions`. There is no email in this app by
   design, but an unmissable banner on the next sign-in, naming the repository, would have shortened
   14 hours to minutes.
3. **Proactive liveness check.** A periodic `GET /user` per subscriber, well inside the rate limit,
   detects a dead token before a delivery does. This does not keep the feature working; it keeps the
   *user* informed, which is the next best thing.

### 7.2 What does not work

- **Storing a personal access token instead.** Same revocation surface, worse security posture, and
  it asks the user to do something GitHub actively discourages.
- **Expiring tokens with refresh.** §2 — solves expiry, and expiry is not the problem.
- **Re-authenticating the user from the background job.** There is nobody there. This is the whole
  difficulty.

### 7.3 One fix that is independent of all of this

`WebhookSubscription::MAX_CONSECUTIVE_FAILURES = 20` with `broken` as a one-way door is what turned a
recoverable incident into permanent damage. The count is a proxy for "nobody is coming back to fix
this," but what it actually measures is delivery *volume* — a busy repository burns 20 failures in an
afternoon while a quiet one would take a month for the same signal. The comment in
`webhook_subscription.rb` reasons carefully about why a token failure should suspend rather than
kill, and then hands the kill decision to a counter that has nothing to do with tokens.

A time-based threshold ("no success in 30 days") measures the thing the design is actually reaching
for. This is worth changing whichever direction the auth decision goes, and it is by far the cheapest
item in this document.

---

## 8. Recommendation

**Register a second registration — a GitHub App — and give it the webhook job. Leave sign-in,
browsing, and every user-driven write on the existing OAuth App.**

Prism has two requirements that pull in opposite directions, and the mistake would be to pick one
credential for both:

- *Browsing must reach everything the user can see.* Only an OAuth App token does this without an
  org owner's involvement (§6.2). `github-api.md` §1.1 got this right and it is still right.
- *Webhooks must run with nobody signed in.* Only an installation access token does this (§4.2). No
  configuration of an OAuth App can.

The hybrid gets both, and the seam is clean because the two paths already barely touch: the webhook
path is `WebhooksController → ProcessDeliveryJob → Announcer → Description → MarkerBlock`, and the
only thing it shares with the UI is `Github::Client`. The cost is one extra app registration, one
private key in the environment, an `installations` table, and rewriting the subscribe screen as an
install link. The risk that §6.2 identifies — losing the repo picker — is not taken at all, because
sign-in does not move.

Three things make this more attractive than it first looks: webhook permissions shrink from `repo`
(full read/write on all code) to Pull requests: write plus Contents: read; per-repo hook management
disappears entirely (§6.4); and webhook traffic stops competing with the user's own 5,000/hour
budget (§4.3).

The honest cost is running two registrations, with two consent surfaces and two things to explain.
A full migration (§6) is GitHub's recommended end state and would eventually collapse that back to
one — but it should wait until the `GET /user/repos` question in §6.2 and the GraphQL-permissions
question in §6.3 have been answered by experiment rather than by reading, and until there is a reason
better than tidiness to ask every user to get their org owner's approval.

### Concrete steps

1. **Read `https://github.com/settings/security-log?q=action%3Aoauth_authorization`** for the incident
   window. Two minutes, and it converts §1 from an enumeration into an answer. Everything below is
   worth doing regardless of what it says, but if it says §1.1 (token pushed to a public repo) there
   is a separate and more urgent hygiene problem to fix first.
2. **Fix `MAX_CONSECUTIVE_FAILURES`** (§7.3) — time-based rather than count-based, and revive the one
   subscription that is currently `broken`. Independent of everything else, smallest change here.
3. **Prototype before building.** Register a throwaway GitHub App and establish, against a real repo:
   that a JWT-minted installation token can `PATCH` a pull request body with only Pull requests:
   write; that the `pull_request` delivery carries the installation id; and — for the §6 question —
   what `GET /user/repos` returns for a user access token. Nothing in this document should be treated
   as settled until the first two are seen working.
4. **Register the production GitHub App**: permissions Pull requests (write) + Contents (read);
   subscribe to `pull_request` and `installation_repositories`; webhook URL `PRISM_PUBLIC_URL` +
   `/webhooks/github`; one webhook secret on the registration. Leave "Identifying and authorizing
   users" off entirely — the app never acts as a user, which keeps the consent screen to one thing.
   New environment: `GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY`, `GITHUB_APP_WEBHOOK_SECRET`, all three
   in `render.yaml`, with the private key treated exactly as `AR_ENCRYPTION_PRIMARY_KEY` is.
5. **Add installation-token auth to `Github::Client`.** Add `jwt` to the Gemfile (image rebuild — see
   `AGENTS.md`). A `Github::AppClient` or equivalent that signs the JWT, exchanges it via
   `create_app_installation_access_token`, caches the result for slightly under its hour, and returns
   the same `Github::Types` value objects the rest of the app expects. The `Github::Client` contract
   does not change; only who is holding the token does.
6. **Make `WebhookSubscription` carry an installation, not a user.** Add `installation_id`; keep
   `user_id` for "who set this up" and for the fallback in §7.1. `hook_id`, `secret` and
   `callback_stale?` become dead once a subscription is installation-backed — but not before, so plan
   for both shapes coexisting rather than a migration that assumes a flag day.
7. **Rewrite the subscribe screen** as an install link:
   `https://github.com/apps/<slug>/installations/new/permissions?suggested_target_id=…&repository_ids[]=…`
   (documented in the migration guide, max 100 pre-selected repos), and handle the
   `installation` / `installation_repositories` webhooks to create and retire subscriptions. Delete
   the old OAuth-created repository hook when `installation_repositories.added` arrives, per §6.4 —
   otherwise deliveries double up during the transition.
8. **Rewrite the identity copy.** `docs/webhooks.md` §Identity, and the text above the subscribe
   button. The new claim is: Prism edits the description as `prism[bot]`, not as you; your account is
   not used and cannot be blamed for it; and the block still disappears if you delete it.
9. **System test the whole thing.** Per `AGENTS.md` this is non-negotiable and `webmock` must cover
   every new call — the JWT exchange, the installation token mint, and the `PATCH`. Stub the token
   mint with a near-future `expires_at` and assert the client re-mints rather than reusing a stale
   one; that cache is where this will break in production if it breaks anywhere.

---

## Open questions I could not settle from primary sources

1. **What `GET /user/repos` returns for a GitHub App user access token** (§6.2). The permission block
   and the account-scope rule are each documented; their interaction on a listing endpoint is not.
   Decides how much of the repo picker survives a full migration. **Prototype it.**
2. **Whether GraphQL `resolveReviewThread` works under fine-grained permissions, and which**
   (§6.3). GitHub states outright that GraphQL permissions are undocumented. Compounds an existing
   open risk in `github-api.md` §7.5.
3. **Whether GitHub re-issues the same OAuth token on re-authorization when the grant is unchanged**
   (§1.5). Asserted in `user.rb`, not stated anywhere in the docs either way. Harmless — the code
   does not depend on it — but the comment should say "believed" rather than state it as fact.
4. **Whether a password change or reset revokes OAuth App tokens** (§1.8). Absent from the token
   revocation page, which is otherwise exhaustive. Absence is suggestive, not conclusive.

---

## Sources verified

**Token lifetime and revocation**
- https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/token-expiration-and-revocation
- https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps
- https://raw.githubusercontent.com/github/docs/main/data/reusables/apps/oauth-token-limit.md
- https://raw.githubusercontent.com/github/docs/main/data/features/oauth-token-expiration.yml (`fpt: '*'`, `ghec: '*'`, `ghes: '>=3.23'`)
- https://docs.github.com/en/apps/oauth-apps/maintaining-oauth-apps/activating-optional-features-for-oauth-apps
- https://docs.github.com/en/rest/credentials/revoke

**GitHub Apps — authentication**
- https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation
- https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app
- https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app
- https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-with-a-github-app-on-behalf-of-a-user
- https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app
- https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens
- https://docs.github.com/en/apps/maintaining-github-apps/activating-optional-features-for-github-apps

**GitHub Apps — permissions, webhooks, migration**
- https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app
- https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/using-webhooks-with-github-apps
- https://docs.github.com/en/apps/creating-github-apps/about-creating-github-apps/migrating-oauth-apps-to-github-apps
- https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/differences-between-github-apps-and-oauth-apps
- https://docs.github.com/en/webhooks/webhook-events-and-payloads#pull_request
- https://docs.github.com/en/apps/using-github-apps/saml-and-github-apps

**Per-endpoint permissions** (the "Fine-grained access tokens for …" blocks, generated by GitHub)
- https://docs.github.com/en/rest/pulls/pulls?apiVersion=2022-11-28
- https://docs.github.com/en/rest/pulls/comments?apiVersion=2022-11-28
- https://docs.github.com/en/rest/pulls/reviews?apiVersion=2022-11-28
- https://docs.github.com/en/rest/repos/contents?apiVersion=2022-11-28
- https://docs.github.com/en/rest/repos/repos?apiVersion=2022-11-28
- https://docs.github.com/en/rest/repos/webhooks?apiVersion=2022-11-28
- https://docs.github.com/en/rest/reactions/reactions?apiVersion=2022-11-28
- https://docs.github.com/en/rest/apps/installations?apiVersion=2022-11-28

**Rate limits and SSO**
- https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api
- https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/rate-limits-for-github-apps
- https://docs.github.com/en/enterprise-cloud@latest/rest/overview/other-authentication-methods (the `X-GitHub-SSO` 403/404 behaviour)

**Ruby**
- https://www.rubydoc.info/gems/octokit/Octokit/Client/Apps (`create_app_installation_access_token`, `find_app_installations`)
- https://github.com/octokit/octokit.rb (README — `Octokit::Client.new(bearer_token:)`)

**Checked and found not to carry the fine-grained permission data** (recorded so nobody repeats the attempt)
- https://raw.githubusercontent.com/github/rest-api-description/main/descriptions/api.github.com/api.github.com.json — `x-github` carries only `enabledForGitHubApps`, `category`, `subcategory`, `githubCloudOnly`. The permission requirements exist only in the rendered docs.
