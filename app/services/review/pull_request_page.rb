# frozen_string_literal: true

module Review
  # The Markdown tab: every renderable `.md` file in a pull request, on one
  # page, in the file list's order.
  #
  # This exists because `Review::Page` loads exactly one file, and ten of those
  # in a row would be ten *sequential* GitHub round trips before the first
  # pixel. Measured from this container a REST call is 180-215ms and a GraphQL
  # call 240-350ms, so a ten-file page done naively spends four or five seconds
  # waiting on sockets it could have waited on at the same time.
  #
  # So this class is the shared half of the page and `Review::Page` keeps the
  # per-file half. It does three things a per-file loader cannot:
  #
  # 1. **One `reviewThreads` call for the whole page**, not one per file. It is
  #    the single most expensive request the screen makes and it already
  #    returns every thread in the pull request; each file just filters it.
  # 2. **Concurrent fetches.** The pull request and its file list have to come
  #    first (one tells us the head sha, the other tells us which files exist),
  #    but after that the threads query, the pending-review read and every
  #    file's content are independent, so they go out together and the page
  #    waits for the slowest rather than the sum. Ruby releases the GVL while
  #    a thread waits on a socket, which is exactly the wait we have.
  # 3. **A rendering budget.** Concurrency fixes the network; it cannot fix
  #    the CPU, and parsing + sanitizing + highlighting a 2000-line document
  #    is 360-726ms of work that the GVL serializes anyway. Past
  #    RENDER_BUDGET_BYTES of Markdown the remaining files render as a heading
  #    and a link instead of a document, so one pathological pull request
  #    cannot hold a Puma thread for half a minute. The parse itself is cached
  #    by content digest (Review::ParsedSource), which is what makes the
  #    second visit to a pull request — the one a reviewer makes after every
  #    comment they leave — cost the network and almost nothing else.
  #
  # Measured here with GitHub latency injected at the rates observed from this
  # container (REST 200ms, GraphQL 300ms), cold cache, server render:
  #
  #     files  lines/file  pool of 6  sequential
  #     5      200         1.33s      2.47s
  #     10     200         1.56s      3.83s
  #     10     800         3.16s      5.35s
  #
  # Warm — same head sha, parses cached — the same three pages are 0.55s,
  # 0.61s and 1.14s.
  class PullRequestPage
    # Six, not more. GitHub's own integration guidance is to prefer serial
    # requests, and its secondary limits (100 concurrent requests, 900 points
    # per minute per endpoint) are exactly the shape a burst of file fetches
    # on a large pull request would trip. Six is the compromise: at ~200ms a
    # call it clears twenty fetches in four waves instead of twenty, and it
    # leaves plenty of headroom under every documented ceiling. Past six the
    # curve flattens anyway — the page is already waiting on its slowest call
    # rather than on the sum.
    MAX_CONCURRENCY = 6

    # Measured, not guessed. Rendering cost scales with the source, but not at
    # one rate: ten 2000-line documents cost about 4.9s of CPU at 372 KB when
    # they are dense with code fences and tables, and about 3.1s at 832 KB
    # when they are plain prose. Bytes are the only size we know *before*
    # paying for the parse, so the budget is in bytes and set against the
    # expensive end. 400 KB is roughly five seconds in the worst case, and ten
    # to forty times the total Markdown in an ordinary documentation pull
    # request — so it never fires on real work, which is the point of a
    # backstop.
    RENDER_BUDGET_BYTES = 400_000

    attr_reader :owner, :repo, :number, :pull_request, :files, :markdown_files,
                :other_files, :pages, :threads, :pending_review, :pending_count,
                :pull_request_node_id, :rate_limited_at, :rate_limit_retry_in,
                :threads_error_message

    def self.load(github:, owner:, repo:, number:)
      new(github: github, owner: owner, repo: repo, number: number)
    end

    def initialize(github:, owner:, repo:, number:)
      @github = github
      @owner = owner
      @repo = repo
      @number = number
      @threads = []
      @pending_count = 0
      @sources = {}
      @line_sets = {}
      @deferred = Set.new
      @rate_limited = false
      @threads_unavailable = false

      load_file_list
      load_everything_else
      apply_render_budget
      @pages = markdown_files.map { |file| Page.new(github: github, owner: owner, repo: repo,
                                                     number: number, path: file.path, bundle: self) }
    end

    def any_markdown? = markdown_files.any?

    # --- what Review::Page reads off us --------------------------------------

    def file(path) = markdown_files.find { |candidate| candidate.path == path }

    def line_sets(path) = @line_sets[path]

    # A failed content fetch takes down its own file and nothing else. The
    # other nine documents are what the reviewer came for, and a page that
    # renders nine of them with a sentence on the tenth beats an error screen
    # — the same call the threads query already makes. Review::Page turns the
    # error into that file's `content_problem`.
    def source(path, ref)
      kind, value = @sources[[ path, ref ]]
      kind == :ok ? value : nil
    end

    def source_error(path, ref)
      kind, value = @sources[[ path, ref ]]
      value if kind == :error
    end

    def deferred?(file) = @deferred.include?(file.path)

    def threads_unavailable? = @threads_unavailable

    def rate_limited? = @rate_limited

    # --- page furniture ------------------------------------------------------

    def source_diff_url = "#{pull_request.html_url}/files"

    def changed_block_count = pages.sum(&:changed_block_count)

    private

    attr_reader :github

    # --- loading -------------------------------------------------------------

    # Two calls that cannot be parallel: the head sha comes from the pull
    # request and the file list's cache key is that sha.
    def load_file_list
      @pull_request = github.pull_request(owner, repo, number)
      @pull_request_node_id = @pull_request.node_id
      @files = github.pull_request_files(owner, repo, number, head_sha: @pull_request.head_sha)
      @markdown_files, @other_files = @files.partition(&:markdown?)

      @markdown_files.each { |file| @line_sets[file.path] = Diff::Patch.parse(file.patch) }
    end

    # Everything after the file list, all at once.
    def load_everything_else
      results = in_parallel(review_state_tasks + content_tasks)

      apply_threads(results[:threads])
      apply_pending_review(results[:pending_review])
      content_refs.each { |ref| @sources[ref] = results[[ :content, *ref ]] }
      note_content_rate_limit
    end

    # One file's fetch is that file's problem; a rate limit is the whole
    # page's, because the next thing the reviewer does will hit it too. So a
    # rate-limited content fetch also raises the page-level banner, while
    # still leaving each affected file its own sentence.
    def note_content_rate_limit
      error = @sources.values.filter_map { |kind, value| value if kind == :error }
                      .find { |value| value.is_a?(Github::RateLimited) }
      return if error.nil? || @rate_limited

      @rate_limited = true
      @rate_limited_at = error.reset_at
      @rate_limit_retry_in = error.retry_in
    end

    def review_state_tasks
      [
        Task.new(:threads, ->(client) { client.review_threads(owner, repo, number) }),
        Task.new(:pending_review, ->(client) { client.pending_review(owner, repo, number) })
      ]
    end

    def content_tasks
      content_refs.map do |(path, ref)|
        Task.new([ :content, path, ref ], ->(client) { client.file_content(owner, repo, path, ref: ref) })
      end
    end

    # The same rule Review::Page applies per file, applied to all of them at
    # once: the head side unless the pull request deletes the file, and the
    # base side only when there is deleted content to show. `uniq` matters —
    # two renamed files can share a base path, and asking twice would cost two
    # requests for one answer.
    def content_refs
      @content_refs ||= markdown_files.flat_map { |file| refs_for(file) }
                                      .reject { |(_path, ref)| ref.blank? }.uniq
    end

    def refs_for(file)
      refs = []
      refs << [ file.path, pull_request.head_sha ] unless file.removed?
      refs << [ file.base_path, pull_request.base_sha ] if base_side_needed?(file)
      refs
    end

    def base_side_needed?(file)
      return false if file.added?

      file.removed? || @line_sets[file.path].removed_lines.any?
    end

    # --- review state --------------------------------------------------------

    # Threads and the pending review are the one part of the page worth
    # rendering without: if GitHub will not give us the comments, the documents
    # are still what the reviewer came for, and a banner says what is missing.
    # Same rescue list as Review::Page had, for the same reasons — GraphQL
    # answers NOT_FOUND for cases REST does not, and a 404 here is about the
    # comments, not about the pull request we already loaded.
    def apply_threads(outcome)
      kind, value = outcome
      return note_threads_failure(value) if kind == :error

      @pull_request_node_id = value.pull_request_node_id.presence || @pull_request_node_id
      @threads = value.threads
      @pending_count = value.threads.sum { |thread| thread.comments.count(&:pending?) }
    end

    def note_threads_failure(error)
      raise error unless error.is_a?(Github::Error)

      @threads_unavailable = true

      if error.is_a?(Github::RateLimited)
        @rate_limited = true
        @rate_limited_at = error.reset_at
        # Seconds is the better signal: GitHub sends Retry-After on a secondary
        # limit, where there is no reset timestamp to derive it from.
        @rate_limit_retry_in = error.retry_in
      else
        Rails.logger.warn("Loading review threads failed: #{error.class} #{error.message}")
        @threads_error_message = error.user_message
      end
    end

    # The tray is a nicety next to the documents, so a pending-review read that
    # fails leaves the tray empty rather than taking the page down with it.
    def apply_pending_review(outcome)
      kind, value = outcome
      return @pending_review = value if kind == :ok
      raise value unless value.is_a?(Github::Error)

      Rails.logger.warn("Loading the pending review failed: #{value.class} #{value.message}")
      nil
    end

    # --- the rendering budget ------------------------------------------------

    # Walks the files in the order they are shown and stops rendering once the
    # page has spent its budget, so the reviewer gets the top of a huge pull
    # request quickly instead of the whole of it slowly. Deferred files keep
    # their heading, their diffstat and their place in the jump menu — only the
    # document is missing, and it is one click away on GitHub.
    def apply_render_budget
      spent = 0

      markdown_files.each do |file|
        size = source_bytes(file)
        next @deferred << file.path if spent >= RENDER_BUDGET_BYTES

        spent += size
      end
    end

    def source_bytes(file)
      refs_for(file).sum do |ref|
        outcome = @sources[ref]
        outcome && outcome.first == :ok ? outcome.last.to_s.bytesize : 0
      end
    end

    # --- running work in parallel --------------------------------------------

    Task = Struct.new(:key, :block)
    private_constant :Task

    # Returns `{ key => [:ok, value] | [:error, exception] }`. Nothing is
    # re-raised here: each caller above decides what a failure means for the
    # part of the page it owns, which is the whole reason a threads failure can
    # show a banner while a content failure takes the normal error path.
    def in_parallel(tasks)
      return tasks.to_h { |task| [ task.key, settle { task.block.call(github) } ] } if tasks.size < 2

      queue = Queue.new
      tasks.each { |task| queue << task }
      outcomes = {}
      lock = Mutex.new

      Array.new([ tasks.size, MAX_CONCURRENCY ].min) { worker(queue, outcomes, lock) }.each(&:join)
      outcomes
    end

    # `executor.wrap` is not optional: without it, autoloading a constant for
    # the first time inside a bare thread deadlocks in development. Each worker
    # also builds its own client — Octokit memoizes one Faraday connection per
    # instance, and sharing that across threads is not safe.
    def worker(queue, outcomes, lock)
      Thread.new do
        Thread.current.name = "prism-github"

        Rails.application.executor.wrap do
          client = worker_client

          while (task = next_task(queue))
            outcome = settle { task.block.call(client) }
            lock.synchronize { outcomes[task.key] = outcome }
          end
        end
      end
    end

    def next_task(queue)
      queue.pop(true)
    rescue ThreadError
      nil
    end

    # A test may hand us a double instead of a real client; there is nothing to
    # clone in that case, and a double is not holding a socket either.
    def worker_client
      github.is_a?(Github::Client) ? Github::Client.new(github.user) : github
    end

    def settle
      [ :ok, yield ]
    rescue StandardError => error
      [ :error, error ]
    end
  end
end
