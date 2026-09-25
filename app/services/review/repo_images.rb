# frozen_string_literal: true

module Review
  # What an image URL inside one Markdown file means, and where Prism should
  # point it instead.
  #
  # This is the policy half of the image fix; Markdown::ImageRewriter is the
  # mechanical half. One of these is built per *side* of a file — the head side
  # at the head sha from the head path's directory, the base side at the base
  # sha from the base path's — because that is the only way a removed strip's
  # images still resolve: the picture a pull request deletes still exists on the
  # ref it was deleted from.
  #
  # The rules, in the order they are applied:
  #
  # 1. **A relative path is repository content.** Resolved against the
  #    directory of the Markdown file, exactly as GitHub resolves it, and
  #    rewritten to Prism's image proxy. A leading `/` means the repository
  #    root rather than the web root, which is again GitHub's rule.
  # 2. **An absolute GitHub raw/blob URL naming this repository at a commit
  #    sha** is the same blob written out the long way, so it takes the same
  #    route. The sha requirement is not fussiness: `…/blob/feature/logo/x.png`
  #    cannot be split into a ref and a path without asking GitHub which
  #    branches exist, and guessing wrong is worse than leaving it.
  # 3. **Everything else is left exactly as written** — another site's image,
  #    a `data:` URI, a camo URL inside a comment body, a GitHub URL on a
  #    branch. See the class comment on RepoImagesController for why Prism
  #    proxies repository content and nothing else.
  #
  # Nothing here can produce a URL that points anywhere but the proxy, and the
  # proxy can name nothing but a blob in a repository. There is no path through
  # this class that turns attacker-authored Markdown into a fetch of an
  # arbitrary URL.
  class RepoImages
    # `raw.githubusercontent.com/:owner/:repo/:ref/:path`
    RAW_HOSTS = %w[raw.githubusercontent.com raw.github.com].freeze
    # `github.com/:owner/:repo/(blob|raw)/:ref/:path`
    BLOB_HOSTS = %w[github.com www.github.com].freeze
    BLOB_SEGMENTS = %w[blob raw].freeze

    # "has a scheme", per RFC 3986. Note that this deliberately also catches
    # `javascript:` and `data:` — both fall through to "leave it alone", and
    # the sanitizer has already removed the former.
    HAS_SCHEME = %r{\A[a-zA-Z][a-zA-Z0-9+.\-]*:}
    SHA = /\A\h{40}\z/
    PERCENT_ESCAPE = /%(\h\h)/

    attr_reader :owner, :repo, :ref, :dir

    # The pair for one file: `[head_side, base_side]` is built by Review::Page,
    # which knows both shas and both paths.
    def initialize(owner:, repo:, ref:, dir:)
      @owner = owner.to_s
      @repo = repo.to_s
      @ref = ref.to_s.downcase
      @dir = split_dir(dir)
    end

    # Every URL we mint carries a commit sha, because the route that serves them
    # only accepts one — which is what makes a proxied image immutable and
    # cacheable forever in the reader's browser. A caller without a sha (a test
    # double, a pull request whose base side we never loaded) gets no rewriting
    # at all rather than URLs that would 404 on the route constraint.
    def usable? = ref.match?(SHA) && owner.present? && repo.present?

    # Markdown::ImageRewriter's resolver contract: a `src` in, a replacement
    # URL out, `nil` to leave it as written.
    def call(src)
      return nil unless usable?

      value = src.to_s.strip
      return nil if value.empty?

      segments = repo_path(value)
      return nil if segments.nil?

      proxy_path(segments)
    end

    def to_proc = method(:call).to_proc

    # What makes a parse of these bytes different from a parse of the same bytes
    # in another file. Review::ParsedSource caches on the content digest, and
    # the same README at two paths now renders to two different documents.
    def cache_key = [ owner, repo, ref, dir.join("/") ]

    private

    # @return [Array<String>, nil] repository path segments, or nil to leave the
    #   URL alone.
    def repo_path(value)
      return absolute_repo_path(value) if value.match?(HAS_SCHEME) || value.start_with?("//")
      return nil if value.start_with?("#")

      relative_repo_path(value)
    end

    # ---------------------------------------------------------------- relative

    def relative_repo_path(value)
      target = value.split(/[?#]/, 2).first.to_s
      return nil if target.empty?

      base = target.start_with?("/") ? [] : dir
      normalize(base, split(target))
    end

    # ---------------------------------------------------------------- absolute

    def absolute_repo_path(value)
      uri = URI.parse(value.start_with?("//") ? "https:#{value}" : value)
      return nil unless uri.is_a?(URI::HTTP)

      host = uri.host.to_s.downcase
      segments = uri.path.to_s.split("/").reject(&:empty?)

      return raw_repo_path(segments) if RAW_HOSTS.include?(host)
      return blob_repo_path(segments) if BLOB_HOSTS.include?(host)

      nil
    rescue URI::InvalidURIError
      nil
    end

    # /:owner/:repo/:ref/:path…
    def raw_repo_path(segments)
      claimed_owner, claimed_repo, claimed_ref, *rest = segments
      return nil unless same_repo?(claimed_owner, claimed_repo) && claimed_ref.to_s.match?(SHA)

      normalize([], split(rest.join("/")))
    end

    # /:owner/:repo/(blob|raw)/:ref/:path…
    def blob_repo_path(segments)
      claimed_owner, claimed_repo, kind, claimed_ref, *rest = segments
      return nil unless same_repo?(claimed_owner, claimed_repo)
      return nil unless BLOB_SEGMENTS.include?(kind.to_s) && claimed_ref.to_s.match?(SHA)

      normalize([], split(rest.join("/")))
    end

    # GitHub treats owner and repository names case-insensitively, and people
    # write them either way in a README.
    def same_repo?(claimed_owner, claimed_repo)
      claimed_owner.to_s.casecmp?(owner) && claimed_repo.to_s.casecmp?(repo)
    end

    # ----------------------------------------------------------------- paths

    def split_dir(value)
      directory = File.dirname(value.to_s)
      return [] if directory == "." || directory == "/"

      directory.split("/").reject { |segment| segment.empty? || segment == "." }
    end

    # Resolves `.` and `..` away, so nothing that leaves this method can carry
    # a traversal segment into the GitHub request — whether it was written
    # plainly (`../../x.png`) or smuggled past the URL parser as `%2e%2e`,
    # since decoding happens per segment *before* this runs.
    #
    # Popping off an empty base is a no-op rather than an error: `../../..` from
    # the repository root is simply the repository root, which is what git
    # itself would say, and GitHub answers the resulting path honestly.
    def normalize(base, segments)
      meaningful = segments.reject { |segment| segment.empty? || segment == "." }
      # `.`, `./`, `..`, `a/..` — every one of these names a directory, and a
      # directory is not an image. Left alone rather than rewritten to the
      # directory's own path, which would be a URL that quietly means something
      # else from the one that was written.
      return nil if meaningful.empty? || meaningful.last == ".."

      resolved = base.dup
      meaningful.each { |segment| segment == ".." ? resolved.pop : resolved << segment }
      resolved.empty? ? nil : resolved
    end

    # Split into path segments, decoding as we go, and split again afterwards.
    #
    # The second split is the one that matters. `%2e%2e%2fescape.png` is a
    # single segment until it is decoded, at which point it is `../escape.png`
    # — and left whole it would travel intact into the URL we generate, where
    # the *browser* would resolve the `..` and walk out of the path we meant.
    # Far enough up it would reach the `:owner` and `:repo` segments of our own
    # route and name a different repository. Re-splitting puts every decoded
    # separator back in front of `normalize`, which is the only place `..` is
    # allowed to mean anything.
    def split(target)
      target.split("/").flat_map { |segment| decode(segment).split("/") }
    end

    # Percent-decoding, per segment and on bytes.
    #
    # comrak percent-encodes an image destination on the way out, so `![a](<my
    # chart.png>)` reaches us as `my%20chart.png` and the repository path we
    # have to ask GitHub for is `my chart.png`.
    def decode(segment)
      segment.b.gsub(PERCENT_ESCAPE) { Regexp.last_match(1).hex.chr }
             .force_encoding(Encoding::UTF_8).scrub
    end

    def proxy_path(segments)
      Rails.application.routes.url_helpers.repo_raw_path(
        owner: owner, repo: repo, ref: ref, path: segments.join("/")
      )
    end
  end
end
