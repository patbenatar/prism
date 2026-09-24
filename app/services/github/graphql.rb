# frozen_string_literal: true

module Github
  # Minimal GraphQL transport over the Octokit connection.
  #
  # GraphQL is not optional for Prism: review threads, `isResolved`/`isOutdated`,
  # `bodyHTML`, the `viewerCan*` flags, reactions with `viewerHasReacted`,
  # resolve/unresolve, and adding a draft comment to an existing pending review
  # exist only there. Octokit has no GraphQL support, but its connection is
  # already pointed at api.github.com with the user's token attached, so a plain
  # POST to /graphql rides on it and we avoid a second HTTP client.
  #
  # Two traps this class exists to contain:
  #
  # 1. The body MUST be a pre-serialized JSON string. `Octokit::Connection#request`
  #    does `options[:query] = data.delete(:query)` on any Hash body — it reads
  #    `query` as URL query parameters. Handing it a GraphQL payload as a Hash
  #    silently strips the query out of the body and appends it to the URL, and
  #    the request fails in a way that looks nothing like the cause. Sawyer sends
  #    a String body verbatim, so we serialize first.
  #
  # 2. GraphQL answers HTTP 200 even when it failed. Octokit only inspects the
  #    status, so it raises nothing. Every caller would have to remember to check
  #    the `errors` key; instead this class checks once and raises.
  class GraphQL
    ENDPOINT = "/graphql"

    # GraphQL error `type` values worth mapping onto the same exceptions REST
    # would have produced, so callers handle one vocabulary.
    ERROR_TYPES = {
      "NOT_FOUND" => NotFound,
      "FORBIDDEN" => Forbidden,
      "UNAUTHORIZED" => Unauthorized
    }.freeze

    def initialize(octokit)
      @octokit = octokit
    end

    # Runs a document and returns its `data` as a plain symbol-keyed Hash.
    #
    # We convert away from Sawyer::Resource deliberately. Sawyer defines field
    # accessors through method_missing, so a GraphQL field named like one of its
    # own methods would resolve to the method instead of the data. Plain hashes
    # have no such ambiguity.
    def call(document, variables = {})
      body = { query: document, variables: variables }.to_json
      response = @octokit.post(ENDPOINT, body)

      payload = response.respond_to?(:to_attrs) ? response.to_attrs : response
      # An empty body (Sawyer answers `nil`), a 204, or a 200 carrying
      # something that is not JSON at all. `nil.to_h` used to turn the first
      # two into `{}` here, which every caller then read as "the mutation
      # returned nothing" and passed on as nil — a 200 with no answer looked
      # exactly like a successful write of nothing.
      raise Unconfirmed.new("GitHub's GraphQL API answered with no body.", response_body: response) unless payload.is_a?(Hash)

      errors = Array(payload[:errors]).map { |error| error.deep_stringify_keys }
      raise_graphql_error(errors, payload) if errors.any?

      # No `errors` and no `data` key is not an empty result, it is no result.
      raise Unconfirmed.new("GitHub's GraphQL API answered with neither data nor errors.",
                            response_body: payload) unless payload.key?(:data)

      payload[:data] || {}
    end

    private

    def raise_graphql_error(errors, payload)
      message = errors.filter_map { |error| error["message"] }.join("; ").presence ||
                "GitHub's GraphQL API returned an error."
      type = errors.first["type"] || errors.first.dig("extensions", "code")

      klass = ERROR_TYPES.fetch(type, GraphQLError)
      raise klass.new(message, errors: errors, response_body: payload) if klass == GraphQLError

      # NOT_FOUND / FORBIDDEN carry no extra payload on the mapped classes.
      raise klass.new(message, response_body: payload)
    end
  end
end
