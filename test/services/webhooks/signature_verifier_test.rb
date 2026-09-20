# frozen_string_literal: true

require "test_helper"

class Webhooks::SignatureVerifierTest < ActiveSupport::TestCase
  SECRET = "whsec_0123456789abcdef"
  BODY = '{"action":"opened","number":42}'

  setup { @verifier = Webhooks::SignatureVerifier.new(SECRET) }

  test "accepts a signature GitHub would have sent" do
    signature = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", SECRET, BODY)

    assert @verifier.valid?(payload: BODY, signature: signature)
  end

  test "rejects a signature made with a different secret" do
    signature = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", "not-the-secret", BODY)

    assert_not @verifier.valid?(payload: BODY, signature: signature)
  end

  test "rejects a signature over a different body" do
    signature = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", SECRET, '{"action":"closed"}')

    assert_not @verifier.valid?(payload: BODY, signature: signature)
  end

  test "rejects a missing or blank signature" do
    assert_not @verifier.valid?(payload: BODY, signature: nil)
    assert_not @verifier.valid?(payload: BODY, signature: "")
    assert_not @verifier.valid?(payload: BODY, signature: "   ")
  end

  # Two wrong-length inputs that a naive comparison might not survive at all.
  test "rejects garbage of any length without raising" do
    assert_not @verifier.valid?(payload: BODY, signature: "sha256=")
    assert_not @verifier.valid?(payload: BODY, signature: "x")
    assert_not @verifier.valid?(payload: BODY, signature: "sha256=#{'a' * 1000}")
  end

  test "rejects the right digest without the sha256= prefix" do
    assert_not @verifier.valid?(payload: BODY, signature: OpenSSL::HMAC.hexdigest("SHA256", SECRET, BODY))
  end

  test "rejects everything when the subscription has no secret" do
    empty = Webhooks::SignatureVerifier.new("")

    assert_not empty.valid?(payload: BODY, signature: empty.expected(BODY))
  end

  # The signature is over raw bytes. A body that differs only in whitespace is
  # a different body, which is why the controller must never re-serialize.
  test "is sensitive to whitespace in the body" do
    signature = @verifier.expected(BODY)

    assert_not @verifier.valid?(payload: BODY + "\n", signature: signature)
  end
end
