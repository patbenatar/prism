# frozen_string_literal: true

# GitHub OAuth is the only way into Prism. There is no password, no email, and
# no registration step.
#
# We register an OAuth App rather than a GitHub App deliberately: a GitHub App's
# user token can only reach accounts where the app has been installed, which
# would leave the repository picker empty for most people until an org owner
# acted. See docs/research/github-api.md §1.1.
Rails.application.config.middleware.use OmniAuth::Builder do
  provider :github,
           ENV["GITHUB_CLIENT_ID"],
           ENV["GITHUB_CLIENT_SECRET"],
           # `repo` is coarse — full read and write on code — but it is the only
           # scope that permits writing pull request review comments, and it is
           # what grants private-repo access. `read:org` backs the @-mention
           # list and org repo visibility; `read:user` the profile.
           #
           # `offline_access` grants no permission at all. GitHub documents it
           # as the way to "opt in to receive an expiring token and a refresh
           # token for an individual sign-in" — per sign-in, whether or not
           # the OAuth App has "Expire user authorization tokens" switched on.
           #
           # Production has that setting on, so the pair arrives with or
           # without this. Development is a separate registration that may
           # not, which would leave the whole refresh path dead code locally
           # and live code in production. Asking explicitly makes the two
           # agree, and makes the pair something Prism receives because it
           # asked rather than because of a checkbox in a settings page nobody
           # working on the code can see.
           #
           # Two things follow. It may come back in `extra.scope` and be
           # stored in `token_scopes`, which is harmless — nothing reads that
           # list except `can_write_reviews?`, which looks for `repo`. And the
           # code has to work without it anyway: a non-expiring token arrives
           # with no refresh token and no expiry, and `User#refreshable?` is
           # false for the rest of its life. See Github::Credentials, and
           # docs/research/github-auth-longevity.md §2 for the quotation.
           scope: "repo,read:org,read:user,offline_access"
end

# OmniAuth 2 rejects a GET request phase. omniauth-rails_csrf_protection then
# verifies Rails' authenticity token on the POST, which is what closes
# CVE-2015-9284. The sign-in control must therefore be a `button_to`, not a link.
OmniAuth.config.allowed_request_methods = %i[post]
OmniAuth.config.silence_get_warning = true

OmniAuth.config.logger = Rails.logger

# Out of the box OmniAuth re-raises failures in development and test, which
# turns a cancelled authorization into a 500. Emptying this list makes every
# environment behave like production: redirect to /auth/failure with a message,
# where SessionsController#failure can explain what happened.
OmniAuth.config.failure_raise_out_environments = []
