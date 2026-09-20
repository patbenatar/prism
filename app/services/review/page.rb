# frozen_string_literal: true

module Review
  # Everything the rendered file view needs, loaded and joined in one place.
  #
  # The controller stays thin because all of this is here: three or four GitHub
  # calls, two Markdown parses, one diff parse, and the BlockMapper call that
  # turns them into the ordered structure the view walks. Nothing in this class
  # touches the request, so it is testable against WebMock fixtures alone.
  #
  # Loading is deliberately lazy about the things it does not need. A file that
  # is not Markdown stops after the file list — we only need its blob URL to
  # redirect to GitHub — and a file with no base side never asks for one.
  class Page
    # The path isn't among the pull request's changed files. Rendering it would
    # mean guessing at a diff that does not exist, so the controller 404s.
    FileNotFound = Class.new(StandardError)

    # Parsing, sanitizing and highlighting all happen on the request thread,
    # and the cost scales with the file: a 2000-line document is about 0.4s, so
    # a multi-megabyte one would hold a Puma thread far longer than anyone will
    # wait for a page. GitHub tells us nothing about a blob's size before we
    # fetch it, so the ceiling is applied after the download and before the
    # parse, which is where the time actually goes. Well above any document a
    # human wrote: 1.5 MB is roughly 25,000 lines of prose.
    MAX_SOURCE_BYTES = 1_500_000

    attr_reader :owner, :repo, :number, :path, :pull_request, :file, :files,
                :result, :pending_review, :pending_count, :head_source,
                :base_source, :threads, :rate_limited_at, :rate_limit_retry_in,
                :threads_error_message

    # A stable, DOM-safe key for this file's section of the review page.
    #
    # Derived from the path, not from its position in the file list, because it
    # is also the URL fragment a link to a file uses: an anchor keyed by index
    # would point at a different document the moment the pull request gains or
    # loses a file. Ten hex characters of SHA-256 over the path is the same
    # trick GitHub's own `#diff-<sha>` fragments use.
    def self.file_key(path) = "f-#{Digest::SHA256.hexdigest(path.to_s)[0, 10]}"

    def self.load(github:, owner:, repo:, number:, path:)
      new(github: github, owner: owner, repo: repo, number: number, path: path)
    end

    # `bundle` is a Review::PullRequestPage when this file is one of many on
    # the Markdown tab: the pull request, the file list, the threads and every
    # file's source have already been loaded once and shared, so this makes no
    # GitHub calls of its own. Without one it loads its own file, which is what
    # the single-file path and most of the unit tests still do.
    def initialize(github:, owner:, repo:, number:, path:, bundle: nil)
      @github = github
      @bundle = bundle
      @owner = owner
      @repo = repo
      @number = number
      @path = path
      @threads = []
      @pending_count = 0
      @rate_limited = false
      @threads_unavailable = false

      load_pull_request
      return unless markdown?

      load_sources
      load_review_state
      @result = map_blocks
    end

    # --- what kind of file is this ------------------------------------------

    def markdown? = file.markdown?

    # This file's anchor on the Markdown tab, and the prefix that makes every
    # block id on the page unique. Markdown::Renderer numbers blocks from zero
    # per document, so two files whose first block is the same heading produce
    # the same block id — harmless when a page held one file, an id collision
    # now that it holds all of them.
    def file_key = self.class.file_key(file.path)

    # The page spent its rendering budget before reaching this file, so it is
    # listed but not rendered. See Review::PullRequestPage::RENDER_BUDGET_BYTES.
    def deferred? = @bundle&.deferred?(file) || false

    # The side we render. v1 shows HEAD plus strips of deleted content; a file
    # the pull request deletes has no head side at all, so it renders from BASE.
    def source = file.removed? ? base_source : head_source

    # GitHub sent no diff: a pure rename, a binary, or a diff over its size
    # limit. The file still renders, but nothing in it can be line-commented.
    def no_patch? = !file.patch?

    # Why the document is not on the page, or nil when it is. Both cases end at
    # the same fallback — a link to GitHub — but they are different sentences,
    # and Prism says which one applies.
    def content_problem
      return :unavailable if content_error
      return :deferred if deferred?
      return :too_large if too_large?
      return :missing_content if source.blank? || binary?(source)

      nil
    end

    # GitHub answered the content request with something other than the file.
    # A 404 is not this — Github::Client turns that into nil, which is the
    # ordinary "no such side" case and reads as :missing_content. This is a
    # rate limit, a 500, a repository mid-transfer: the file is missing from
    # the page for a reason that has nothing to do with the file.
    attr_reader :content_error

    # GitHub's own sentence for why, so the notice says something true rather
    # than something generic.
    def content_error_message
      content_error.respond_to?(:user_message) ? content_error.user_message : content_error&.message
    end

    def missing_content? = content_problem.present?

    def renderable? = !missing_content?

    # Either side counts. The base side is parsed too, for the removed strips,
    # so an enormous base would cost the same as an enormous head.
    def too_large?
      [ head_source, base_source ].compact.any? { |text| text.bytesize > MAX_SOURCE_BYTES }
    end

    # --- counts and navigation ----------------------------------------------

    def changed_block_count
      return 0 if result.nil?

      result.blocks.count(&:changed?)
    end

    def file_index = files.index(file)

    def prev_file
      index = file_index
      files[index - 1] if index&.positive?
    end

    def next_file
      index = file_index
      files[index + 1] if index
    end

    # --- GitHub links --------------------------------------------------------

    # The blob at the sha we rendered, so "View on GitHub" shows the same bytes.
    def github_blob_url
      file.blob_url.presence || "https://github.com/#{owner}/#{repo}/blob/#{blob_ref}/#{file.path}"
    end

    def source_diff_url = "#{pull_request.html_url}/files"

    # The base a file-level comment's permalink is built from, per
    # Review::FileCommentBody. E's composer appends "#L12-L18".
    def file_comment_permalink_base
      "https://github.com/#{owner}/#{repo}/blob/#{pull_request.head_sha}/#{path}"
    end

    # --- threads -------------------------------------------------------------

    # Threads on content this pull request deleted, for the strip that renders
    # it. Review::BlockMapper decides the placement — a LEFT thread whose line
    # belongs to a deleted block goes on the strip, which still shows the text
    # the comment is about, rather than beside whatever replaced it.
    def removed_strip_threads(base_block)
      return [] if result.nil?

      result.threads_for_strip(base_block)
    end

    # Threads the mapper could place nowhere. Rendered with the outdated ones at
    # the foot of the page rather than dropped.
    def unattached_threads = Array(result&.unplaced_threads)

    # GitHub would not give us the comments, so the page rendered without them.
    # The two cases read differently to a reviewer: a rate limit ends at a known
    # time and anything else is just missing, so they are separate predicates
    # rather than one flag with a misleading name.
    def threads_unavailable? = @threads_unavailable

    def rate_limited? = @rate_limited

    # The node id every write mutation needs. review_threads hands it over for
    # free alongside the threads; the pull request itself carries it when that
    # call failed.
    def pull_request_node_id = @pull_request_node_id.presence || pull_request.node_id

    private

    attr_reader :github

    # --- loading -------------------------------------------------------------

    def load_pull_request
      if @bundle
        @pull_request = @bundle.pull_request
        @files = @bundle.markdown_files
        @file = @bundle.file(path)
      else
        @pull_request = github.pull_request(owner, repo, number)
        all_files = github.pull_request_files(owner, repo, number, head_sha: @pull_request.head_sha)

        @files = all_files.select(&:markdown?)
        @file = all_files.find { |candidate| candidate.path == path }
      end

      raise FileNotFound, "#{path} is not part of pull request ##{number}" if @file.nil?
    end

    # The base side is only ever used for two things: rendering a file this
    # pull request deletes, and building the strips of content it removed. A
    # diff with no deletions in it needs neither, so an addition-only file
    # costs one GitHub call and one Markdown parse instead of two — which on a
    # 2000-line document is most of the page's render time.
    def load_sources
      @line_sets = @bundle&.line_sets(file.path) || Diff::Patch.parse(file.patch)

      @head_source = read(file.path, pull_request.head_sha) unless file.removed?
      @base_source = read(file.base_path, pull_request.base_sha) if base_side_needed?
      @content_error = rendering_side_error
    end

    # Only the side this file renders from counts as "the document is not
    # here". A base fetch that failed costs the reviewer the removed strips,
    # not the document, and blanking a readable page over it would be worse
    # than losing them — when the cause is a rate limit or an outage, which it
    # almost always is, the page-level banner says so anyway.
    def rendering_side_error
      return nil if @bundle.nil?

      file.removed? ? @bundle.source_error(file.base_path, pull_request.base_sha)
                    : @bundle.source_error(file.path, pull_request.head_sha)
    end

    def base_side_needed?
      return false if file.added?

      file.removed? || @line_sets.removed_lines.any?
    end

    def read(at_path, ref)
      return nil if ref.blank?

      return @bundle.source(at_path, ref) if @bundle

      github.file_content(owner, repo, at_path, ref: ref)
    end

    # Threads and the pending review are the one part of the page that is worth
    # rendering without: if GitHub will not give us the comments, the document
    # itself is still what the reviewer came for, and a banner says what is
    # missing.
    #
    # NotFound is in the list because GraphQL answers NOT_FOUND for cases REST
    # does not — a token that can read the pull request but not query it that
    # way, or partial data on a repository mid-transfer. The pull request has
    # already loaded by this point, so a 404 here is about the comments, not
    # about the file, and 404ing the whole screen over it would be wrong.
    def load_review_state
      return copy_review_state_from_bundle if @bundle

      all_threads = github.review_threads(owner, repo, number)
      @pull_request_node_id = all_threads.pull_request_node_id
      @threads = all_threads.threads.select { |thread| paths.include?(thread.path) }
      @pending_count = all_threads.threads.sum { |thread| thread.comments.count(&:pending?) }
      @pending_review = github.pending_review(owner, repo, number)
    rescue Github::RateLimited => error
      @rate_limited = true
      @threads_unavailable = true
      @rate_limited_at = error.reset_at
      # Seconds is the better signal: GitHub sends Retry-After on a secondary
      # limit, where there is no reset timestamp to derive it from.
      @rate_limit_retry_in = error.retry_in
    rescue Github::NotFound, Github::Forbidden, Github::Unavailable => error
      Rails.logger.warn("Loading review threads failed: #{error.class} #{error.message}")
      @threads_unavailable = true
      @threads_error_message = error.user_message
    end

    # One reviewThreads call served the whole page, so this is a filter, not a
    # fetch. The pending count is deliberately the page's, not this file's:
    # the tray counts every unsubmitted draft in the pull request.
    def copy_review_state_from_bundle
      @pull_request_node_id = @bundle.pull_request_node_id
      @threads = @bundle.threads.select { |thread| paths.include?(thread.path) }
      @pending_count = @bundle.pending_count
      @pending_review = @bundle.pending_review
      @rate_limited = @bundle.rate_limited?
      @threads_unavailable = @bundle.threads_unavailable?
      @rate_limited_at = @bundle.rate_limited_at
      @rate_limit_retry_in = @bundle.rate_limit_retry_in
      @threads_error_message = @bundle.threads_error_message
    end

    # A rename moves the path, and GitHub keeps older threads on the old one.
    def paths = [ file.path, file.previous_path ].compact

    def map_blocks
      return nil unless renderable?

      BlockMapper.call(
        head_blocks: parse(head_source),
        base_blocks: parse(base_source),
        line_sets: @line_sets,
        threads: threads,
        path: file.path,
        file_status: file.status
      )
    end

    # Through ParsedSource rather than straight to Markdown::Document: the
    # parse is the page's largest single cost and a pure function of the bytes
    # at a sha, so it is cached alongside the content it came from.
    def parse(text) = ParsedSource.blocks(text, user_id: cache_scope)

    # A test may hand us a double instead of a real client; an unscoped cache
    # is still correct (the key is the content's own digest), so this shrugs
    # rather than raising.
    def cache_scope = github.respond_to?(:user) ? github.user&.id : nil

    def blob_ref = file.removed? ? pull_request.base_sha : pull_request.head_sha

    # GitHub hands us text for anything it will serve as a blob, but a file with
    # NUL bytes in it is not a document a reviewer can read.
    def binary?(text) = text.include?("\u0000")
  end
end
