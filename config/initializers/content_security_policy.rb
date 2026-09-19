# frozen_string_literal: true

# Content Security Policy.
#
# Prism renders HTML that came from GitHub — a pull request description, a
# comment body, a Markdown file someone else wrote. All of it is sanitized
# first (`ApplicationHelper#github_html`, later `Markdown::Sanitizer`), but the
# sanitizer is one layer and this is the other: if a tag ever slips the
# safelist, the browser still refuses to run it.
#
# Enforced, not report-only, in every environment. The system suite drives real
# Chromium, so a directive that breaks the app fails a test rather than
# reaching a user.
#
# See DESIGN.md §4 for the origin-by-origin rationale.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self

    # No inline scripts and no event-handler attributes anywhere in the app;
    # the only inline tags are importmap's, which carry the nonce below.
    policy.script_src :self

    # 'self' for the Tailwind build, Google Fonts for the stylesheet link, and
    # the nonce for the <style> Turbo injects for its progress bar (Turbo reads
    # `csp-nonce` and sets it on that element — verified in turbo.js).
    policy.style_src :self, "https://fonts.googleapis.com"

    # Style ATTRIBUTES are a separate directive, and nonces cannot apply to an
    # attribute. Prism needs exactly one: a GitHub label is drawn in the colour
    # the repository chose, which only an inline `style` can express, since the
    # value is data rather than a class.
    #
    # The exposure is bounded. The only inline style we emit comes from
    # `ApplicationHelper#label_pill_style`, which parses GitHub's hex with a
    # strict `\A\h{6}\z` match and re-emits it through `format("#%02x%02x%02x")`
    # — a value that cannot carry anything but three numbers. And `style` is
    # not in `GITHUB_HTML_ATTRIBUTES`, so the sanitizer strips it from every
    # piece of GitHub-authored HTML. Nothing attacker-controlled reaches here.
    policy.style_src_attr :unsafe_inline

    policy.font_src :self, "https://fonts.gstatic.com"

    # Avatars come from avatars.githubusercontent.com, and an image in a
    # rendered Markdown file can be hosted anywhere. There is no allowlist that
    # would cover "whatever the document links to", so this is `https:` — which
    # still rules out http:, and images are not a script execution vector.
    policy.img_src :self, :https, :data

    # Turbo only ever talks to us. Nothing in Prism calls GitHub from the
    # browser: every GitHub request is made server-side with the user's token,
    # which is what keeps that token out of the page in the first place.
    policy.connect_src :self

    # A form posts to us. The one exception is the OAuth request phase: the
    # sign-in button POSTs to /auth/github, and the OmniAuth middleware answers
    # with a redirect to github.com. Browsers differ on whether form-action is
    # re-checked against a redirect target, so github.com is listed rather than
    # left to chance.
    #
    # NOTE: this one directive is not covered by a test. OmniAuth's test mode
    # short-circuits the request phase and redirects straight to our callback,
    # so no suite can exercise the real hop to github.com. Verify it by hand
    # against a real OAuth app before trusting it in production.
    policy.form_action :self, "https://github.com"

    # Prism is never framed, embeds no plugins, and no page may rewrite the
    # base URL out from under a relative link.
    policy.frame_ancestors :none
    policy.object_src :none
    policy.base_uri :self
  end

  # A fresh nonce per request.
  #
  # Rails' own suggestion is `request.session.id.to_s`, which is friendlier to
  # full-page caching — but Prism caches no pages, and a signed-out visitor has
  # no session id yet. That would render `nonce-` on the sign-in page and block
  # every importmap tag on it. A random nonce has neither problem.
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }

  # style-src takes the nonce so Turbo's injected <style> is allowed without
  # opening inline styles generally. style-src-attr deliberately does not: a
  # nonce cannot apply to an attribute, and adding one here would silently
  # cancel the `unsafe-inline` the label pills depend on.
  config.content_security_policy_nonce_directives = %w[script-src style-src]
end
