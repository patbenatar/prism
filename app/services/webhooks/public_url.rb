# frozen_string_literal: true

module Webhooks
  # The origin the outside world reaches this Prism at.
  #
  # Everything else in the app builds paths, because everything else answers a
  # request and can take the host from it. These two cannot: the callback URL
  # is handed to GitHub at registration, and the review link is read by people
  # on github.com. Both need an absolute URL, and in development "localhost"
  # is not one — hence PRISM_PUBLIC_URL, which in development is the tunnel
  # hostname (see docs/webhooks.md) and in production is the app's own origin.
  #
  # Nothing here falls back to the request's host. A webhook callback pointed
  # at whatever Host header happened to arrive is how you end up registering a
  # hook against someone else's domain.
  class PublicUrl
    ENV_KEY = "PRISM_PUBLIC_URL"

    class << self
      def base = ENV[ENV_KEY].to_s.strip.presence

      def configured? = base.present?

      # Host, protocol and port for a Rails `*_url` helper.
      def url_options
        raise MissingPublicUrl unless configured?

        uri = URI.parse(base)
        raise MissingPublicUrl unless uri.is_a?(URI::HTTP) && uri.host.present?

        options = { protocol: uri.scheme, host: uri.host }
        options[:port] = uri.port unless uri.port == uri.default_port
        options
      rescue URI::InvalidURIError
        raise MissingPublicUrl
      end

      # The hostname alone, for config.hosts in development.
      def host
        url_options[:host]
      rescue MissingPublicUrl
        nil
      end
    end
  end
end
