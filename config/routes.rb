Rails.application.routes.draw do
  # GitHub-shaped URLs. A reviewer can swap github.com for localhost:3004 in the
  # address bar and land on the same pull request, so the paths below mirror
  # GitHub's own (/:owner/:repo/pulls/:number/files/...) rather than Rails'
  # resourceful defaults.
  #
  # Phase 1 note: Workstream C owns this file and has added every route from
  # PLAN.md up front, including the commenting routes whose controllers land in
  # Phase 2. Rails only resolves a controller constant when a request hits the
  # route, so the missing ones are harmless until then and nobody else has to
  # edit this file.

  # Health check for load balancers and uptime monitors.
  get "up" => "rails/health#show", as: :rails_health_check

  # ── Session ────────────────────────────────────────────────────────────
  # POST /auth/github is served by the OmniAuth middleware, not by a route.
  # omniauth-rails_csrf_protection requires the request phase to be a POST, so
  # the sign-in page uses button_to, never link_to.
  get    "/sign_in",              to: "sessions#new"
  get    "/auth/github/callback", to: "sessions#create"
  post   "/auth/github/callback", to: "sessions#create"
  get    "/auth/failure",         to: "sessions#failure"
  delete "/session",              to: "sessions#destroy", as: :session

  # ── Browsing ───────────────────────────────────────────────────────────
  get "/repos", to: "repos#index", as: :repos

  # Keyed by owner+name, not a PinnedRepo id: the client only ever knows a
  # repo's owner/name (from GitHub), never one of our row ids. Placed ahead of
  # the generic "/:owner/:repo" scope below, which would otherwise treat
  # "pins" as an :owner segment.
  post   "/repos/pins",              to: "pinned_repos#create",  as: :pinned_repos
  delete "/repos/pins/:owner/:repo", to: "pinned_repos#destroy", as: :pinned_repo,
         constraints: { owner: /[^\/]+/, repo: /[^\/]+/ }

  # ── Webhooks (W5) ──────────────────────────────────────────────────────
  # The one unauthenticated route in the app. GitHub posts a delivery here and
  # it is authenticated by its X-Hub-Signature-256 HMAC, not by a session —
  # see app/controllers/webhooks_controller.rb for why that is enough.
  post "/webhooks/github", to: "webhooks#create", as: :github_webhook

  # Which repositories Prism watches, and as whom. Single-segment, so above
  # the "/:owner/:repo" scope.
  get    "/subscriptions",     to: "webhook_subscriptions#index",   as: :webhook_subscriptions
  post   "/subscriptions",     to: "webhook_subscriptions#create"
  # Re-points an existing hook at the current PRISM_PUBLIC_URL, which a dev
  # tunnel changes on every restart.
  patch  "/subscriptions/:id", to: "webhook_subscriptions#update",  as: :webhook_subscription
  delete "/subscriptions/:id", to: "webhook_subscriptions#destroy"

  # There is no dashboard: the first useful screen is the repository list.
  root to: redirect("/repos", status: 302)

  # ── Everything scoped to a repository ──────────────────────────────────
  # This scope matches any two-segment path, so it stays last — /repos and
  # /sign_in are single-segment and are matched above regardless, but keeping
  # the order explicit means a future single-segment route can't be swallowed.
  scope "/:owner/:repo", constraints: { owner: /[^\/]+/, repo: /[^\/]+/ }, as: :repo do
    get "pulls",         to: "pull_requests#index"                  # ?state=open|closed|all
    get "pulls/:number", to: "pull_requests#show", as: :pull

    # The Markdown tab (W3): every renderable .md file in the pull request on
    # one page. `PullRequestFilesController#index`.
    get "pulls/:number/markdown", to: "pull_request_files#index", as: :pull_markdown

    # The old per-file screen's URL. Kept alive as a redirect into the
    # Markdown tab's anchor for that file, so links from before the tab
    # existed still land on the right place. `format: false` keeps ".md" as
    # part of the path instead of being parsed as a response format.
    get "pulls/:number/files/*path", to: "pull_request_files#show", as: :pull_file, format: false

    # ── Commenting (Phase 2, workstream E) ───────────────────────────────
    scope "pulls/:number", as: :pull do
      post   "comments",                            to: "review_comments#create"
      post   "comments/:id/replies",                to: "review_comments#reply",    as: :comment_replies
      patch  "comments/:id",                        to: "review_comments#update",   as: :comment
      delete "comments/:id",                        to: "review_comments#destroy"
      post   "comments/:id/reactions",              to: "reactions#create",         as: :comment_reactions
      delete "comments/:id/reactions/:reaction_id", to: "reactions#destroy",        as: :comment_reaction

      post   "reviews/:id/submit", to: "reviews#submit", as: :review_submit
      delete "reviews/:id",        to: "reviews#destroy", as: :review

      post "threads/:id/resolve",   to: "review_threads#resolve",   as: :thread_resolve
      post "threads/:id/unresolve", to: "review_threads#unresolve", as: :thread_unresolve
    end

    # JSON for the @-mention autocomplete, and the Markdown preview fragment.
    get  "mentionables",     to: "mentionables#index"
    post "markdown/preview", to: "markdown_previews#create", as: :markdown_preview
  end
end
