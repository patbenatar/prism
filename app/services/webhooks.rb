# frozen_string_literal: true

# Everything behind Prism's one unauthenticated endpoint.
#
# This is the first part of Prism that acts without a human in the request, so
# the shape is deliberately narrow:
#
#   WebhooksController          verifies the HMAC, rejects replays, and returns
#                               200 without doing any work
#   ProcessDeliveryJob          runs the work as the subscribing user
#   Webhooks::Announcer         decides what *should* be on the pull request
#   Webhooks::AnnouncementTarget  decides *where* it goes (see that file — it
#                               is the seam for swapping the description for a
#                               comment)
#   Webhooks::MarkerBlock       the byte-exact splice, pure Ruby, no network
#   Webhooks::SignatureVerifier constant-time X-Hub-Signature-256 check
#   Webhooks::Registrar         creates and deletes the hook on GitHub
#
# Nothing here trusts a delivery payload for anything except "which
# subscription is this, and which pull request". Every fact Prism acts on —
# does this pull request have Markdown, what does its body say right now — is
# read back from GitHub with the subscriber's own token.
module Webhooks
  # Raised when a delivery is structurally wrong: unparseable JSON, no
  # repository, no pull request number. Always a 400, never a retry.
  class MalformedDelivery < StandardError; end

  # Raised when Prism is not configured with a public URL, so there is nothing
  # to point a hook or a review link at.
  class MissingPublicUrl < StandardError
    def message
      "Prism has no public URL. Set PRISM_PUBLIC_URL (see docs/webhooks.md) " \
        "before subscribing a repository."
    end
  end

  # Subscribing or unsubscribing failed in a way the person can do something
  # about. Carries wording meant for them, not for a log.
  class RegistrationError < StandardError
    def initialize(message)
      super
    end

    def user_message = message
  end
end
