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

  # There is no dashboard: the first useful screen is the repository list.
  root to: redirect("/repos", status: 302)

  # ── Everything scoped to a repository ──────────────────────────────────
  # This scope matches any two-segment path, so it stays last — /repos and
  # /sign_in are single-segment and are matched above regardless, but keeping
  # the order explicit means a future single-segment route can't be swallowed.
  scope "/:owner/:repo", constraints: { owner: /[^\/]+/, repo: /[^\/]+/ }, as: :repo do
    get "pulls",         to: "pull_requests#index"                  # ?state=open|closed|all
    get "pulls/:number", to: "pull_requests#show", as: :pull

    # The rendered Markdown file view. `format: false` keeps ".md" as part of
    # the path instead of being parsed as a response format.
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
