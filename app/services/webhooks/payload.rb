# frozen_string_literal: true

module Webhooks
  # The few fields Prism reads out of a delivery, and nothing else.
  #
  # A `pull_request` payload is tens of kilobytes describing the pull request,
  # its head and base, its author and the repository. Prism reads four values
  # from it — which repository, which action, which pull request — and throws
  # the rest away, because every fact it acts on is fetched back from GitHub
  # with the subscriber's token. That is not fastidiousness: the payload is
  # attacker-supplied until the HMAC checks out, and the repository lookup has
  # to happen *before* the check in order to find the secret to check with.
  # Keeping the pre-verification surface to "which row is this" is what makes
  # that ordering safe.
  class Payload
    # The actions worth a GitHub round trip. `edited` is deliberately absent:
    # Prism's own description edit produces one, and acting on it would be an
    # infinite loop. `closed` is absent because a merged pull request's link
    # still works and removing it would be noise.
    ACTIONABLE = %w[opened reopened synchronize ready_for_review].freeze

    attr_reader :action, :repository_id, :repository_full_name, :pull_request_number

    def self.parse(raw_body)
      data = JSON.parse(raw_body.to_s)
      raise MalformedDelivery, "Delivery body is not a JSON object" unless data.is_a?(Hash)

      new(data)
    rescue JSON::ParserError => error
      raise MalformedDelivery, "Delivery body is not valid JSON: #{error.message}"
    end

    def initialize(data)
      repository = data["repository"] || {}
      pull_request = data["pull_request"] || {}

      @action = data["action"].to_s.presence
      @repository_id = repository["id"]
      @repository_full_name = repository["full_name"].to_s
      @pull_request_number = pull_request["number"]
    end

    def repository? = repository_id.present? || repository_full_name.include?("/")

    def actionable? = ACTIONABLE.include?(action) && pull_request_number.present?
  end
end
