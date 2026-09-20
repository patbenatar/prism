# frozen_string_literal: true

module Webhooks
  # Verifies GitHub's X-Hub-Signature-256 header.
  #
  # GitHub computes HMAC-SHA256 over the *raw* request body with the secret we
  # gave it at registration, and sends it as "sha256=<hex>". The body has to be
  # the bytes as received: re-serializing the parsed JSON would change
  # whitespace and key order and every signature would fail.
  #
  # The comparison is constant time. A byte-by-byte `==` leaks, through timing,
  # how much of a guessed signature was correct, which turns forging one from
  # impossible into merely tedious. ActiveSupport::SecurityUtils.secure_compare
  # digests both sides first, so it is also safe when the lengths differ —
  # which they will, every time someone sends a garbage header.
  class SignatureVerifier
    PREFIX = "sha256="
    HEADER = "X-Hub-Signature-256"

    attr_reader :secret

    def initialize(secret)
      @secret = secret.to_s
    end

    # `payload` must be the raw request body, `signature` the header value.
    def valid?(payload:, signature:)
      return false if secret.empty?
      return false if signature.blank?

      ActiveSupport::SecurityUtils.secure_compare(expected(payload), signature.to_s)
    end

    def expected(payload)
      PREFIX + OpenSSL::HMAC.hexdigest("SHA256", secret, payload.to_s)
    end
  end
end
