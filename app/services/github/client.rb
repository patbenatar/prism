# frozen_string_literal: true

module Github
  # The only thing in Prism that talks to GitHub.
  #
  # Everything it returns is a Github::Types value object, so the rest of the app
  # depends on a small stable interface instead of Octokit's Sawyer resources or
  # GraphQL's camelCase hashes. Every request is made as the signed-in user with
  # their own token, which means authorization is entirely GitHub's problem: the
  # client never has to decide who may see what.
  #
  # REST goes through Octokit; threads, drafts, reactions and resolve go through
  # Github::GraphQL because they exist nowhere else. See
  # docs/research/github-api.md for the verified endpoint behaviour behind each
  # method, and PLAN.md for the contract this implements.
  class Client
    PER_PAGE = 100

    # Raw file bytes rather than the base64 JSON envelope.
    RAW_MEDIA_TYPE = "application/vnd.github.raw"

    # TTLs from PLAN.md "Caching, limits, failure modes". Threads and reviews are
    # deliberately absent: they change while the user is looking at them, and
    # GraphQL offers no ETag to make a conditional request cheap.
    TTL = {
      viewer: 1.hour,
      repos: 60.seconds,
      repo: 60.seconds,
      pull_requests: 30.seconds,
      pull_request: 15.seconds,
      files: 15.seconds,
      # A pull request's patch is immutable for a given head sha, so once we know
      # the sha we can hold it far longer than the 15s blind cache.
      files_by_sha: 1.day,
      content: 7.days,
      mentionables: 10.minutes,
      markdown: 1.day
    }.freeze

    # GitHub's REST reaction names and their GraphQL enum counterparts. We speak
    # REST style everywhere in the app because it matches what the API returns in
    # a reaction rollup, and translate only at the mutation boundary.
    REACTIONS = {
      "+1" => "THUMBS_UP",
      "-1" => "THUMBS_DOWN",
      "laugh" => "LAUGH",
      "confused" => "CONFUSED",
      "heart" => "HEART",
      "hooray" => "HOORAY",
      "rocket" => "ROCKET",
      "eyes" => "EYES"
    }.freeze
    GRAPHQL_REACTIONS = REACTIONS.invert.freeze

    attr_reader :user

    def initialize(user)
      @user = user
    end

    # ---------------------------------------------------------------- reads ---

    # The signed-in GitHub account. Cheap, cached for an hour, and useful as a
    # liveness check on the token.
    def viewer
      data = cached(:viewer, ttl: TTL[:viewer]) { attrs(get("/user")) }
      build_author(data)
    end

    # One page of repositories the user can reach, most recently pushed first.
    # The caller paginates; the repo picker filters in the browser rather than
    # burning requests on a search-as-you-type.
    def repos(page: 1)
      data = cached(:repos, page, ttl: TTL[:repos]) do
        get("/user/repos", sort: "pushed", direction: "desc", per_page: PER_PAGE, page: page)
          .map { |repo| attrs(repo) }
      end
      data.map { |repo| build_repo(repo) }
    end

    def repo(owner, name)
      data = cached(:repo, owner, name, ttl: TTL[:repo]) { attrs(get(repo_path(owner, name))) }
      build_repo(data)
    end

    def pull_requests(owner, name, state: "open", page: 1)
      data = cached(:pull_requests, owner, name, state, page, ttl: TTL[:pull_requests]) do
        get("#{repo_path(owner, name)}/pulls",
            state: state, sort: "updated", direction: "desc", per_page: PER_PAGE, page: page)
          .map { |pull| attrs(pull) }
      end
      data.map { |pull| build_pull_request(pull) }
    end

    def pull_request(owner, name, number)
      data = cached(:pull_request, owner, name, number, ttl: TTL[:pull_request]) do
        attrs(get("#{repo_path(owner, name)}/pulls/#{number}"))
      end
      build_pull_request(data)
    end

    # Every changed file, auto-paginated. GitHub caps the response at 3000 files
    # and omits `patch` for binaries and oversized diffs — a file with no patch
    # has no commentable lines at all, which PullRequestFile#patch? exposes.
    #
    # Pass head_sha when you have it: the patch is immutable for a given sha, so
    # it earns a day of caching instead of fifteen seconds.
    def pull_request_files(owner, name, number, head_sha: nil)
      key = head_sha ? [ :files_by_sha, owner, name, number, head_sha ] : [ :files, owner, name, number ]
      ttl = head_sha ? TTL[:files_by_sha] : TTL[:files]

      data = cached(*key, ttl: ttl) do
        paginate("#{repo_path(owner, name)}/pulls/#{number}/files").map { |file| attrs(file) }
      end
      data.map { |file| build_pull_request_file(file) }
    end

    # The file's bytes at a commit, or nil when it does not exist on that side —
    # which is the normal case for an added file's base side and a removed file's
    # head side, not an error.
    def file_content(owner, name, path, ref:)
      cached(:content, owner, name, ref, path, ttl: TTL[:content]) do
        begin
          body = get(contents_path(owner, name, path), ref: ref, accept: RAW_MEDIA_TYPE)
          body.to_s.dup.force_encoding(Encoding::UTF_8).scrub
        rescue NotFound
          nil
        end
      end
    end

    # Never cached: a review the user just submitted must show up immediately.
    def reviews(owner, name, number)
      get("#{repo_path(owner, name)}/pulls/#{number}/reviews", per_page: PER_PAGE)
        .map { |review| build_review(attrs(review)) }
    end

    # The viewer's unsubmitted draft, if they have one. GitHub allows exactly one
    # per user per pull request, and hides other people's, but we match on login
    # anyway rather than trust that.
    def pending_review(owner, name, number)
      reviews(owner, name, number).find do |review|
        review.pending? && review.author&.login&.casecmp?(user.login)
      end
    end

    # Every review thread with its comments, fully paginated, plus the pull
    # request's node id — which every write mutation needs, so fetching it here
    # saves a round trip.
    def review_threads(owner, name, number)
      node_id = nil
      threads = []
      cursor = nil

      loop do
        data = gql(Queries::REVIEW_THREADS, owner: owner, name: name, number: number, cursor: cursor)
        pull = data.dig(:repository, :pullRequest)
        raise NotFound, "Pull request #{owner}/#{name}##{number} not found." if pull.nil?

        node_id ||= pull[:id]
        page = pull[:reviewThreads] || {}
        threads.concat(Array(page[:nodes]).compact.map { |thread| build_thread(hydrate_comments(thread)) })

        info = page[:pageInfo] || {}
        break unless info[:hasNextPage]

        cursor = info[:endCursor]
      end

      Types::ReviewThreadsResult.new(pull_request_node_id: node_id, threads: threads)
    end

    # People who can be @-mentioned here.
    #
    # There is no public endpoint equivalent to GitHub's own mention
    # autocomplete, so we union what is reachable: collaborators when the user
    # has write access, assignees when they do not, org members when the owner is
    # an organization, and whoever is already on the pull request. GitHub does
    # not validate mentions on write, so an incomplete list costs nothing but
    # convenience — which is why every branch here degrades instead of raising.
    def mentionables(owner, name, participants: [])
      data = cached(:mentionables, owner, name, ttl: TTL[:mentionables]) do
        (collaborators(owner, name) + organization_members(owner)).map { |person| attrs(person) }
      end

      people = data.map { |person| build_mentionable(person) } + Array(participants).map { |p| coerce_mentionable(p) }
      people.compact.uniq(&:login).sort_by { |person| person.login.downcase }
    end

    # GitHub's own renderer, so @mentions and #123 references link the way they
    # will once the comment is posted. Only used for live preview: existing
    # comments already carry GraphQL's bodyHTML for free.
    def render_markdown(text, context:)
      return "" if text.blank?

      digest = Digest::SHA256.hexdigest("#{context}\n#{text}")
      cached(:markdown, digest, ttl: TTL[:markdown]) do
        post("/markdown", text: text, mode: "gfm", context: context).to_s
      end
    end

    # --------------------------------------------------------------- writes ---

    # Posts a comment immediately, as its own one-comment review.
    def create_thread(pull_request_node_id:, anchor:, body:)
      input = { pullRequestId: pull_request_node_id, body: body }.merge(anchor.to_graphql)
      data = gql(Queries::ADD_THREAD, input: input)
      build_thread(data.dig(:addPullRequestReviewThread, :thread))
    end

    # Adds a draft comment to an existing pending review. This mutation is the
    # only way to do it: REST has no endpoint that appends to a pending review,
    # so the alternative would be deleting and recreating the whole review.
    def add_thread_to_review(review_node_id:, anchor:, body:)
      input = { pullRequestReviewId: review_node_id, body: body }.merge(anchor.to_graphql)
      data = gql(Queries::ADD_THREAD, input: input)
      build_thread(data.dig(:addPullRequestReviewThread, :thread))
    end

    # Immediate reply to a submitted thread. REST is the simpler call here, and
    # it wants the thread's root comment id, not the thread id.
    def reply(owner, name, number, root_comment_id, body:)
      data = post("#{repo_path(owner, name)}/pulls/#{number}/comments/#{root_comment_id}/replies", body: body)
      build_comment_from_rest(attrs(data))
    end

    # Draft reply inside a pending review.
    def reply_in_review(review_node_id:, thread_node_id:, body:)
      data = gql(Queries::ADD_THREAD_REPLY,
                 input: { pullRequestReviewId: review_node_id,
                          pullRequestReviewThreadId: thread_node_id,
                          body: body })
      build_comment(data.dig(:addPullRequestReviewThreadReply, :comment))
    end

    # Works on submitted comments and pending drafts alike.
    def update_comment(comment_node_id, body:)
      data = gql(Queries::UPDATE_COMMENT,
                 input: { pullRequestReviewCommentId: comment_node_id, body: body })
      build_comment(data.dig(:updatePullRequestReviewComment, :pullRequestReviewComment))
    end

    def delete_comment(comment_node_id)
      gql(Queries::DELETE_COMMENT, input: { id: comment_node_id })
      true
    end

    # Opens an empty draft review. GitHub permits one per user per pull request,
    # so a 422 here almost always means one already exists — in which case the
    # right answer is to hand back the existing one rather than surface an error.
    def create_pending_review(owner, name, number, commit_id:)
      data = post("#{repo_path(owner, name)}/pulls/#{number}/reviews", commit_id: commit_id)
      build_review(attrs(data))
    rescue Unprocessable => error
      pending_review(owner, name, number) || raise(error)
    end

    def submit_review(owner, name, number, review_id, event:, body: nil)
      payload = { event: event }
      payload[:body] = body if body.present?

      data = post("#{repo_path(owner, name)}/pulls/#{number}/reviews/#{review_id}/events", **payload)
      build_review(attrs(data))
    end

    def delete_pending_review(owner, name, number, review_id)
      delete("#{repo_path(owner, name)}/pulls/#{number}/reviews/#{review_id}")
      true
    end

    def resolve_thread(thread_node_id)
      data = gql(Queries::RESOLVE_THREAD, input: { threadId: thread_node_id })
      build_thread(hydrate_comments(data.dig(:resolveReviewThread, :thread)))
    end

    def unresolve_thread(thread_node_id)
      data = gql(Queries::UNRESOLVE_THREAD, input: { threadId: thread_node_id })
      build_thread(hydrate_comments(data.dig(:unresolveReviewThread, :thread)))
    end

    # `content` is REST style ("+1", "heart"); GitHub's GraphQL enum spells the
    # same things differently, so translate at the boundary.
    def add_reaction(comment_node_id, content:)
      data = gql(Queries::ADD_REACTION,
                 input: { subjectId: comment_node_id, content: graphql_reaction(content) })
      build_comment(data.dig(:addReaction, :subject))
    end

    def remove_reaction(comment_node_id, content:)
      data = gql(Queries::REMOVE_REACTION,
                 input: { subjectId: comment_node_id, content: graphql_reaction(content) })
      build_comment(data.dig(:removeReaction, :subject))
    end

    private

    # ------------------------------------------------------------ transport ---

    # auto_paginate only changes the behaviour of Octokit#paginate, which this
    # client calls in exactly one place (pull_request_files). Plain #get is
    # unaffected, so the repo and pull request lists still return one page and
    # let the caller decide whether to ask for more. Without this flag
    # Octokit#paginate silently returns only the first page.
    def octokit
      @octokit ||= Octokit::Client.new(
        access_token: user.access_token,
        per_page: PER_PAGE,
        auto_paginate: true
      )
    end

    def graphql
      @graphql ||= Github::GraphQL.new(octokit)
    end

    def get(path, **params) = translate_errors { octokit.get(path, params) }

    def post(path, **body) = translate_errors { octokit.post(path, body) }

    def delete(path, **body) = translate_errors { octokit.delete(path, body) }

    def paginate(path, **params)
      translate_errors { octokit.paginate(path, params.merge(per_page: PER_PAGE)) }
    end

    def gql(document, **variables) = translate_errors { graphql.call(document, variables) }

    def repo_path(owner, name) = "/repos/#{escape(owner)}/#{escape(name)}"

    # The contents endpoint takes a real path, so slashes must survive; only the
    # individual segments get escaped.
    def contents_path(owner, name, path)
      segments = path.to_s.split("/").map { |segment| escape(segment) }.join("/")
      "#{repo_path(owner, name)}/contents/#{segments}"
    end

    def escape(value) = ERB::Util.url_encode(value.to_s)

    # ---------------------------------------------------------------- cache ---

    # Always namespaced by user id. Two people looking at the same private
    # repository must never share a cache entry, because their tokens may grant
    # different access to it.
    def cached(*key_parts, ttl:)
      Rails.cache.fetch([ "github", user.id, *key_parts ], expires_in: ttl) { yield }
    end

    # --------------------------------------------------------------- errors ---

    # Normalizes Octokit and Faraday failures into the Github::Error hierarchy so
    # controllers rescue one vocabulary and never see an HTTP status.
    def translate_errors
      yield
    rescue Octokit::Unauthorized => error
      raise Unauthorized.new(github_message(error), **error_details(error))
    rescue Octokit::TooManyRequests, Octokit::AbuseDetected => error
      raise rate_limited(error)
    rescue Octokit::Forbidden => error
      raise Forbidden.new(github_message(error), **error_details(error))
    rescue Octokit::NotFound => error
      raise NotFound.new(github_message(error), **error_details(error))
    rescue Octokit::UnprocessableEntity => error
      raise unprocessable(error)
    rescue Octokit::ServerError => error
      raise Unavailable.new(github_message(error), **error_details(error))
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => error
      raise Unavailable.new(error.message)
    end

    def error_details(error)
      { status: error.response_status,
        response_body: error.response_body,
        documentation_url: error.documentation_url }
    end

    # Octokit's message is prefixed with the method and URL, which is noise in a
    # flash message. GitHub's own `message` field is the useful part.
    def github_message(error)
      body = error.response_body
      parsed = body.is_a?(String) ? (JSON.parse(body) rescue nil) : body
      (parsed.is_a?(Hash) && (parsed["message"] || parsed[:message]).presence) || error.message
    end

    def rate_limited(error)
      headers = error.response_headers || {}
      retry_after = headers["retry-after"] || headers["Retry-After"]

      RateLimited.new(github_message(error),
                      reset_at: error.context&.resets_at,
                      retry_after: retry_after&.to_i,
                      **error_details(error))
    end

    # The one 422 worth its own class: the anchor line is not inside any hunk of
    # the file's patch, which is the constraint the whole rendered-file view has
    # to work around.
    def unprocessable(error)
      messages = Array(error.errors).map { |e| e.is_a?(Hash) ? (e[:message] || e["message"]) : e }.compact
      combined = ([ github_message(error) ] + messages).join(" ")

      return LineNotCommentable.new(combined, **error_details(error)) if combined.match?(/must be part of the diff/i)

      Unprocessable.new(github_message(error), errors: messages, **error_details(error))
    end

    # -------------------------------------------------------------- mapping ---

    # Sawyer resources become plain symbol-keyed hashes before anything reads
    # them, so a field named like one of Sawyer's own methods cannot shadow data.
    def attrs(resource)
      return {} if resource.nil?
      return resource if resource.is_a?(Hash)

      resource.respond_to?(:to_attrs) ? resource.to_attrs : resource.to_h
    end

    def build_author(data)
      return nil if data.blank?

      Types::Author.new(
        login: data[:login],
        avatar_url: data[:avatar_url] || data[:avatarUrl],
        html_url: data[:html_url] || data[:url]
      )
    end

    def build_repo(data)
      owner = data[:owner] || {}

      Types::Repo.new(
        id: data[:id],
        owner: owner[:login],
        name: data[:name],
        full_name: data[:full_name],
        private: data[:private],
        description: data[:description],
        default_branch: data[:default_branch],
        pushed_at: timestamp(data[:pushed_at]),
        open_issues_count: data[:open_issues_count],
        html_url: data[:html_url],
        owner_avatar_url: owner[:avatar_url],
        owner_type: owner[:type]
      )
    end

    def build_pull_request(data)
      head = data[:head] || {}
      base = data[:base] || {}

      Types::PullRequest.new(
        number: data[:number],
        node_id: data[:node_id],
        title: data[:title],
        body: data[:body],
        state: data[:state],
        draft: data[:draft],
        # The list endpoint returns a slimmer pull request than the show
        # endpoint: it sends merged_at and no `merged` key at all. Reading only
        # `merged` made every merged pull request render as "Closed" in the
        # list. merged_at is present on both shapes, so prefer it and keep
        # `merged` as the fallback for the show payload.
        merged: data[:merged_at].present? || data[:merged].present?,
        author: build_author(data[:user]),
        head_sha: head[:sha],
        base_sha: base[:sha],
        head_ref: head[:ref],
        base_ref: base[:ref],
        created_at: timestamp(data[:created_at]),
        updated_at: timestamp(data[:updated_at]),
        labels: Array(data[:labels]).map { |l| Types::Label.new(name: l[:name], color: l[:color]) },
        html_url: data[:html_url],
        changed_files: data[:changed_files],
        additions: data[:additions],
        deletions: data[:deletions]
      )
    end

    def build_pull_request_file(data)
      Types::PullRequestFile.new(
        path: data[:filename],
        previous_path: data[:previous_filename],
        status: data[:status],
        additions: data[:additions],
        deletions: data[:deletions],
        patch: data[:patch],
        blob_url: data[:blob_url]
      )
    end

    def build_review(data)
      Types::Review.new(
        id: data[:id],
        node_id: data[:node_id],
        # A pending review comes back with state "PENDING"; normalize case so
        # callers can compare against one spelling.
        state: data[:state]&.to_s&.upcase,
        body: data[:body],
        author: build_author(data[:user]),
        submitted_at: timestamp(data[:submitted_at]),
        commit_id: data[:commit_id],
        html_url: data[:html_url]
      )
    end

    # A thread's comments come back one page at a time like anything else in
    # GraphQL. We ask for 100, which covers nearly every thread, but a long
    # argument silently loses everything past the hundredth comment unless we
    # follow hasNextPage — and silently losing review comments is the worst
    # failure this client could have.
    #
    # This works on the raw payload rather than inside build_thread on purpose.
    # build_thread stays a pure mapping function with no network in it, which is
    # what lets the Markdown engine's contract test convert fixture nodes to
    # value objects without stubbing HTTP.
    def hydrate_comments(thread_data)
      return thread_data if thread_data.blank?

      page = thread_data[:comments] || {}
      return thread_data unless page.dig(:pageInfo, :hasNextPage)

      nodes = Array(page[:nodes]).compact
      cursor = page.dig(:pageInfo, :endCursor)

      loop do
        data = gql(Queries::THREAD_COMMENTS, threadId: thread_data[:id], cursor: cursor)
        following = data.dig(:node, :comments) || {}
        nodes.concat(Array(following[:nodes]).compact)

        info = following[:pageInfo] || {}
        break unless info[:hasNextPage]

        # A cursor that does not advance would loop forever, hanging the request
        # and burning rate limit on identical calls. Stopping is not silent
        # truncation in any realistic case; it only fires on a malformed page.
        break if info[:endCursor] == cursor

        cursor = info[:endCursor]
      end

      thread_data.merge(comments: { nodes: nodes, pageInfo: { hasNextPage: false, endCursor: nil } })
    end

    def build_thread(data)
      return nil if data.blank?

      comments = Array(data.dig(:comments, :nodes)).compact.map { |c| build_comment(c) }

      Types::ReviewThread.new(
        node_id: data[:id],
        path: data[:path],
        line: data[:line],
        original_line: data[:originalLine],
        start_line: data[:startLine],
        original_start_line: data[:originalStartLine],
        diff_side: data[:diffSide],
        start_diff_side: data[:startDiffSide],
        subject_type: data[:subjectType],
        is_resolved: data[:isResolved],
        is_outdated: data[:isOutdated],
        resolved_by: build_author(data[:resolvedBy]),
        viewer_can_resolve: data[:viewerCanResolve],
        viewer_can_unresolve: data[:viewerCanUnresolve],
        viewer_can_reply: data[:viewerCanReply],
        comments: comments
      )
    end

    def build_comment(data)
      return nil if data.blank?

      Types::ReviewComment.new(
        id: data[:databaseId],
        node_id: data[:id],
        author: build_author(data[:author]),
        body: data[:body],
        body_html: data[:bodyHTML],
        state: data[:state],
        created_at: timestamp(data[:createdAt]),
        url: data[:url],
        diff_hunk: data[:diffHunk],
        outdated: data[:outdated],
        viewer_can_update: data[:viewerCanUpdate],
        viewer_can_delete: data[:viewerCanDelete],
        viewer_can_react: data[:viewerCanReact],
        reply_to_node_id: data.dig(:replyTo, :id),
        reaction_groups: build_reaction_groups(data[:reactionGroups])
      )
    end

    # A REST reply response is thinner than the GraphQL comment: no bodyHTML, no
    # viewerCan* flags, no reaction groups. The viewer flags are safe to assert
    # because you just wrote it; bodyHTML stays nil and the caller either renders
    # the raw body or refetches the thread.
    def build_comment_from_rest(data)
      Types::ReviewComment.new(
        id: data[:id],
        node_id: data[:node_id],
        author: build_author(data[:user]),
        body: data[:body],
        body_html: data[:body_html],
        # A reply posted through this endpoint is live immediately; only a
        # comment added to a pending review is ever PENDING, and that path goes
        # through GraphQL.
        state: "SUBMITTED",
        created_at: timestamp(data[:created_at]),
        url: data[:html_url],
        diff_hunk: data[:diff_hunk],
        outdated: data[:line].nil?,
        viewer_can_update: true,
        viewer_can_delete: true,
        viewer_can_react: true,
        reply_to_node_id: nil,
        reaction_groups: []
      )
    end

    def build_reaction_groups(groups)
      Array(groups).filter_map do |group|
        count = group.dig(:reactors, :totalCount).to_i
        next if count.zero?

        Types::ReactionGroup.new(
          content: GRAPHQL_REACTIONS.fetch(group[:content], group[:content]),
          count: count,
          viewer_has_reacted: group[:viewerHasReacted]
        )
      end
    end

    def build_mentionable(data)
      Types::Mentionable.new(
        login: data[:login],
        name: data[:name],
        avatar_url: data[:avatar_url] || data[:avatarUrl]
      )
    end

    # Participants arrive as Author or Mentionable value objects, or as bare
    # logins from a caller that only has strings.
    def coerce_mentionable(person)
      case person
      when Types::Mentionable then person
      when String then Types::Mentionable.new(login: person, name: nil, avatar_url: nil)
      else
        return nil unless person.respond_to?(:login)

        Types::Mentionable.new(
          login: person.login,
          name: person.try(:name),
          avatar_url: person.try(:avatar_url)
        )
      end
    end

    def timestamp(value)
      return nil if value.blank?
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)

      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def graphql_reaction(content)
      REACTIONS.fetch(content.to_s) do
        raise ArgumentError, "Unknown reaction #{content.inspect}"
      end
    end

    # ------------------------------------------------------- mentionables ---

    # Collaborators is the better list but needs write access; assignees is the
    # read-only fallback and is what a reviewer without push rights will get.
    def collaborators(owner, name)
      get("#{repo_path(owner, name)}/collaborators", per_page: PER_PAGE)
    rescue Forbidden, NotFound
      begin
        get("#{repo_path(owner, name)}/assignees", per_page: PER_PAGE)
      rescue Forbidden, NotFound
        []
      end
    end

    # A 404 here just means the owner is a user account, not an organization, so
    # there is no member list to union in.
    def organization_members(owner)
      get("/orgs/#{escape(owner)}/members", per_page: PER_PAGE)
    rescue NotFound, Forbidden
      []
    end
  end
end
