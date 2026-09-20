# frozen_string_literal: true

module Webhooks
  class AnnouncementTarget
    # Prism's block lives in the pull request description, between HTML comment
    # markers, and nothing else in the description is ever touched. See
    # MarkerBlock for the splice and the exact guarantee.
    #
    # Every operation reads the body back from GitHub first, uncached. There is
    # no conditional update on this endpoint — no If-Match, no expected
    # revision — so the window between reading and writing is the whole of our
    # exposure to clobbering an author's edit; a cached body would widen that
    # window from milliseconds to the cache TTL for no gain.
    #
    # Keep the read uncached and immediately before the write. Caching it,
    # batching the calls, or hoisting the read earlier all widen the only
    # window in which Prism can destroy someone's writing. This was weighed
    # against using a pull request comment, which has no such window; the
    # description won on placement. See docs/webhooks.md.
    class Description < AnnouncementTarget
      def current_content
        MarkerBlock.content_of(body)
      end

      # True when the description actually changed. A redelivery of the same
      # event computes the identical body and writes nothing.
      def place(content)
        write(MarkerBlock.apply(body, content))
      end

      def retract
        write(MarkerBlock.remove(body))
      end

      private

      def body
        @body ||= pull_request.body.to_s
      end

      def pull_request
        @pull_request ||= client.pull_request(owner, repo, number, fresh: true)
      end

      def write(new_body)
        return false if new_body == body

        client.update_pull_request_body(owner, repo, number, body: new_body)
        @body = new_body
        true
      end
    end
  end
end
