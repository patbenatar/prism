# frozen_string_literal: true

module Webhooks
  # The URL GitHub delivers to, derived from PRISM_PUBLIC_URL.
  #
  # Its own object because two very different things need it and must agree
  # exactly: Registrar, when it tells GitHub where to POST, and
  # WebhookSubscription, when it asks "is the URL I registered still the one
  # we'd register today?". A string built in two places is a string that
  # eventually differs in a trailing slash and makes every subscription look
  # stale.
  class CallbackUrl
    # Raises MissingPublicUrl when Prism has no public origin configured.
    def self.current
      Rails.application.routes.url_helpers.github_webhook_url(**PublicUrl.url_options)
    end

    # nil instead of raising, for callers that are only comparing — a screen
    # rendering a list should not blow up because a variable is unset, it
    # should say so.
    def self.current_or_nil
      current
    rescue MissingPublicUrl
      nil
    end
  end
end
