# frozen_string_literal: true

# Serves one image out of a repository, as the signed-in user.
#
# ## Why this exists at all
#
# Prism's whole point is reading documents, and a proposal whose charts are
# broken-image icons is not the document. Two separate things stand between a
# Markdown `![chart](chart.png)` and a picture on the screen, and only the
# first is about URLs:
#
# 1. The destination is relative to the *Markdown file*, so the browser
#    resolves it against throughprism.dev and 404s. Review::RepoImages fixes
#    that by rewriting it to a URL that names the blob.
# 2. **The repository is private.** No absolute URL helps here. An `<img>` tag
#    is an unauthenticated cross-origin GET: the browser has no GitHub token
#    and must never be given one, so `raw.githubusercontent.com` answers it
#    with a 404 just as it would a stranger. The bytes can only reach the page
#    through something that holds the user's token, which is the server.
#
# So the server fetches and streams. GitHub does exactly the same thing for
# exactly the same reason; theirs is called camo.
#
# ## Why this is not an open proxy
#
# It takes no URL. It takes an owner, a repository, a commit sha and a path,
# and the only thing it can do with them is call GitHub's contents endpoint —
# there is no code path here that fetches a host the caller chose. Path
# traversal is resolved away in Review::RepoImages before a URL is ever minted
# and again here before one is ever honoured, so `..` cannot walk out of the
# repository; and since the destination is always the GitHub API, walking out
# of the repository would not reach anything interesting even if it could.
#
# **Authorization is GitHub's, as everywhere else in Prism.** The fetch is made
# with the signed-in user's own token, so a request for a repository they
# cannot see returns GitHub's 404 and we show the "unavailable" placeholder.
# Prism never decides who may see a repository, and deliberately does not
# confirm that a private one exists — which is also why every failure here
# looks identical from outside.
#
# Nothing restricts this to the repository whose page the reader is on, and
# nothing should: signing the URLs would bind an image to a page but would not
# make a single byte available that the user could not already fetch from
# GitHub themselves. The boundary that matters is the token's, and that one is
# enforced by GitHub on every request.
#
# ## Why the response is locked down
#
# The bytes are a stranger's file being served from Prism's own origin, so the
# content type is decided by *sniffing the bytes*, never by the extension, and
# only the image signatures below are served at all. On top of that every
# response carries `Content-Security-Policy: default-src 'none'; sandbox`,
# which is what makes SVG safe to serve: an SVG is a document, it can contain
# script, and script in a same-origin document is a session-stealing XSS.
# `sandbox` drops the response into an opaque origin with scripting off, so an
# SVG opened directly in a tab can reach nothing of Prism's. CSP headers are
# not enforced on a subresource, so this costs nothing when the same file is
# loaded the ordinary way, through `<img>`.
class RepoImagesController < ApplicationController
  # This action's response is not a page, and the app-wide policy (which exists
  # to constrain *our* HTML) would be the wrong one for it. It sets its own —
  # far tighter — policy below.
  content_security_policy false

  # A ceiling on what we will hold in memory and hand to Puma. Comfortably
  # above any chart or screenshot in a document — the two PNGs that started
  # this are 120 KB each — and far below GitHub's own 100 MB limit on what the
  # contents endpoint will serve, which is the real worst case if this were
  # unbounded.
  MAX_BYTES = 5.megabytes

  # The URL names a commit, so the bytes behind it can never change. `private`
  # is the load-bearing word: these are one user's view of a repository that
  # may be private, and a shared cache must never hold them.
  IMMUTABLE = "private, max-age=31536000, immutable"

  # A failure is re-asked next time — the file may appear, the rate limit will
  # lift — so it must not be what a browser remembers at this URL.
  TRANSIENT = "no-store"

  IMAGE_POLICY = "default-src 'none'; sandbox"

  # Magic numbers, longest and most specific first. Deliberately not derived
  # from the file extension: the extension is attacker-chosen and the bytes are
  # what the browser will actually parse.
  SIGNATURES = [
    [ "image/png",  "\x89PNG\r\n\x1A\n".b ],
    [ "image/gif",  "GIF87a".b ],
    [ "image/gif",  "GIF89a".b ],
    [ "image/jpeg", "\xFF\xD8\xFF".b ],
    [ "image/x-icon", "\x00\x00\x01\x00".b ]
  ].freeze

  # RIFF and ISO-BMFF put their brand at an offset rather than at byte zero.
  CONTAINER_SIGNATURES = [
    [ "image/webp", "RIFF".b, 8, %w[WEBP] ],
    [ "image/avif", nil,      4, %w[ftypavif ftypavis ftypmif1 ftypheic ftypheix] ]
  ].freeze

  # An SVG is text, so there is no magic number to match; this is the marker
  # and the window it has to appear in. Anything that reaches here is served
  # under the sandbox policy above, so a file that is really HTML pretending to
  # be SVG still cannot run.
  SVG_MARKER = %r{<svg[\s/>]}i
  SVG_WINDOW = 1024

  # Shown in place of an image we could not serve, for any reason: the file was
  # deleted in this pull request, it lives only on the other side, it is a PDF
  # someone linked as a picture, it is 40 MB, GitHub is rate limiting us, or
  # the reader cannot see that repository. Deliberately one placeholder for all
  # of them — a distinguishable "forbidden" would be an oracle for whether a
  # private repository exists, and the reader can do nothing differently in any
  # of these cases anyway.
  #
  # Transparent, with the one grey that carries on both the light and the dark
  # canvas (between --color-ink-faint's two sides). The rounded border and the
  # spacing around it come from `.md-prose img` in the stylesheet, so this
  # inherits the design system rather than restating it, and the `<img>`'s own
  # alt text still describes it to a screen reader.
  PLACEHOLDER = <<~SVG.freeze
    <svg xmlns="http://www.w3.org/2000/svg" width="320" height="180" viewBox="0 0 320 180">
      <rect width="320" height="180" fill="#7a8099" fill-opacity="0.08"/>
      <g fill="none" stroke="#7a8099" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <rect x="130" y="58" width="60" height="46" rx="5"/>
        <circle cx="146" cy="74" r="5"/>
        <path d="M133 98l15-13 11 9 9-7 17 14"/>
        <path d="M124 52l72 58"/>
      </g>
      <text x="160" y="132" text-anchor="middle" fill="#7a8099"
            font-family="system-ui, -apple-system, 'Segoe UI', sans-serif" font-size="13">Image unavailable</text>
    </svg>
  SVG

  def show
    path = repository_path
    return placeholder(:bad_path) if path.nil?

    # The URL carries a commit sha, so a revalidation can be answered without
    # asking GitHub anything — which matters, because every image on the page
    # spends the reader's own rate limit.
    etag = image_etag(path)
    return not_modified(etag) if revalidating?(etag)

    serve(path, etag)
  end

  private

  def owner = params[:owner].to_s

  def name = params[:repo].to_s

  def ref = params[:ref].to_s.downcase

  # Resolved again here, not only in Review::RepoImages. That one runs over
  # authored Markdown; this runs over whatever arrives at the URL, which is not
  # the same trust boundary even though today it is the same traffic.
  def repository_path
    segments = params[:path].to_s.split("/").each_with_object([]) do |segment, resolved|
      case segment
      when "", "." then next
      when ".." then resolved.pop
      else resolved << segment
      end
    end

    return nil if segments.empty? || segments.any? { |segment| segment.include?("\u0000") }

    segments.join("/")
  end

  def serve(path, etag)
    bytes = github.blob(owner, name, path, ref: ref)
    return placeholder(:not_found) if bytes.nil?
    return placeholder(:too_large) if bytes.bytesize > MAX_BYTES

    type = image_type(bytes)
    return placeholder(:not_an_image) if type.nil?

    response.headers["ETag"] = etag
    send_image(bytes, type: type, cache_control: IMMUTABLE)
  rescue Github::NotFound, Github::Forbidden
    # GitHub's 404 *is* the authorization answer, and its 403 (an org that has
    # not approved the OAuth app) is the same answer in a different sentence.
    placeholder(:not_found)
  rescue Github::RateLimited, Github::Unavailable
    placeholder(:unavailable)
  end

  # Pointedly *not* carrying the blob's validator. The ETag names a commit and
  # a path, and this is not what lives there; hand it over here and a browser
  # would revalidate its way back to a placeholder for the rest of the year,
  # long after the rate limit lifted or the file appeared. Rack's own ETag
  # middleware still fingerprints the body, which is harmless — `no-store` is
  # what keeps a failure from being remembered at all.
  def placeholder(reason)
    response.headers["X-Prism-Image"] = reason.to_s
    send_image(PLACEHOLDER, type: "image/svg+xml", cache_control: TRANSIENT)
  end

  def not_modified(etag)
    response.headers["ETag"] = etag
    response.headers["Cache-Control"] = IMMUTABLE
    head :not_modified
  end

  # Headers after `send_data`, not before: it sets Content-Type, Content-Length
  # and Content-Disposition itself, and the response is not committed until the
  # action returns.
  def send_image(bytes, type:, cache_control:)
    send_data bytes, type: type, disposition: "inline"

    response.headers["Cache-Control"] = cache_control
    response.headers["Content-Security-Policy"] = IMAGE_POLICY
    response.headers["X-Content-Type-Options"] = "nosniff"
  end

  # Computed rather than left to `stale?`, which folds the flash and the
  # template digest into its validator — neither of which describes a PNG, and
  # both of which change between two requests for the same bytes, so the 304
  # this exists for would never fire.
  #
  # Strong, because byte-identical is exactly what it claims. Namespaced by user
  # id like every other cached GitHub read: two people looking at the same
  # private repository must not be able to revalidate into each other's answer,
  # even in one browser profile across a sign-out.
  def image_etag(path)
    digest = Digest::SHA256.hexdigest([ current_user.id, owner, name, ref, path ].join("\u0000"))
    %("#{digest}")
  end

  def revalidating?(etag)
    request.headers["If-None-Match"].to_s.split(",").map(&:strip).any? do |candidate|
      candidate == etag || candidate == "*"
    end
  end

  def image_type(bytes)
    SIGNATURES.each { |type, magic| return type if bytes.start_with?(magic) }

    CONTAINER_SIGNATURES.each do |type, prefix, offset, brands|
      next if prefix && !bytes.start_with?(prefix)
      next unless brands.any? { |brand| bytes.byteslice(offset, brand.bytesize) == brand.b }

      return type
    end

    "image/svg+xml" if svg?(bytes)
  end

  def svg?(bytes)
    head = bytes.byteslice(0, SVG_WINDOW).to_s.dup.force_encoding(Encoding::UTF_8)
    head.valid_encoding? && head.match?(SVG_MARKER)
  end
end
