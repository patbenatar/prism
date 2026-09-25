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
  #
  # `images` is in the key because the parse stopped being a pure function of
  # the bytes alone the moment image URLs started being rewritten: the same
  # README at `docs/a/` and `docs/b/`, or at two different shas, renders to two
  # different documents. Its `cache_key` is the repository, the ref and the
  # directory — all stable for as long as the content is — so this costs no
  # hit rate that was ever real.
  module ParsedSource
    TTL = 1.day

    def self.blocks(text, user_id: nil, images: nil)
      return [] if text.blank?

      key = [ "markdown-blocks", user_id, images&.cache_key, Digest::SHA256.hexdigest(text) ]
      Rails.cache.fetch(key, expires_in: TTL) do
        Markdown::Document.parse(text, renderer: Markdown::Renderer.new(images: images)).blocks
      end
    end
  end
end
