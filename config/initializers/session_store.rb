# frozen_string_literal: true

# A 30-day, sliding session. See PLAN.md round 2 (W2) for the choice between
# this and a `sessions` table.
#
# `expire_after` does two things at once, and it is worth spelling out why one
# setting gets both: Rack::Session::Abstract::Persisted#commit_session always
# recomputes `cookie[:expires] = Time.now + options[:expire_after]` when
# writing the Set-Cookie header, and it *always* rewrites that header on a
# request with a non-empty session as long as any of :max_age, :renew, :drop,
# :expire_after is set (see #forced_session_update? / #force_options? in
# rack-session's abstract/id.rb). So merely setting `expire_after` here means
# every authenticated request re-issues the cookie with a fresh "30 days from
# now" expiry — that *is* the sliding refresh, with no extra before_action to
# touch the session by hand. 30 days of no requests at all and the browser
# simply stops sending a cookie that has passed its Max-Age.
#
# Everything else about the cookie is unchanged and still in force: `httponly`
# is Rack's own default (true) and was never overridden; `secure` is forced on
# every cookie in production by `config.force_ssl` (config/environments/production.rb),
# not by an option here; `same_site` defaults to `:lax` via Rails 8's
# `cookies_same_site_protection` default. `reset_session` on sign-in (see
# Authentication#sign_in) still rotates the session id on every login
# regardless of how long the old one had left to live.
Rails.application.config.session_store :cookie_store,
  key: "_prism_app_session",
  expire_after: 30.days
