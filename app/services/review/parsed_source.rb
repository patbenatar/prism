# frozen_string_literal: true

module Review
  # Markdown::Document.parse, memoized on the bytes it parsed.
  #
  # Parsing is the most expensive thing the review screen does and the one
  # thing concurrency cannot help with: comrak, Rouge and the sanitizer all run
  # on the request thread under the GVL, and measured in this container a
  # 2000-line document costs 360-726ms. Ten of those is six seconds of pure
  # CPU behind a page whose network is already down to one wait.
  #
  # It is also the most cacheable thing the screen does. A blob at a sha is
  # immutable, the parse is a pure function of those bytes, and a reviewer
  # reloads this page after every comment they leave — so the second visit to
  # a pull request, and every visit by anyone else to the same head sha, pays
  # the network and none of the parse.
  #
  # The key is the content digest, so a hit is only possible for bytes the
  # caller is already holding: nothing can come back that the caller did not
  # already have. The user id is in the key anyway, because AGENTS.md's rule
  # about namespacing cached GitHub data per user is worth following even
  # where the leak it prevents cannot happen.
  module ParsedSource
    TTL = 1.day

    def self.blocks(text, user_id: nil)
      return [] if text.blank?

      key = [ "markdown-blocks", user_id, Digest::SHA256.hexdigest(text) ]
      Rails.cache.fetch(key, expires_in: TTL) { Markdown::Document.parse(text).blocks }
    end
  end
end
