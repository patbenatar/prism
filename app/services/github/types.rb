# frozen_string_literal: true

# Value objects returned by Github::Client.
#
# Nothing outside app/services/github/** may see an Octokit/Sawyer resource or a
# raw GraphQL hash: the client maps every response into one of these before it
# leaves. They are plain `Data` objects — immutable, comparable, cheap to build
# in a test without touching the network.
#
# The shapes below are the contract PLAN.md freezes for parallel work. Fields are
# never renamed or reordered without a note to the lead. Predicate helpers
# (`markdown?`, `pending?`, …) are additive conveniences and safe to extend.
module Github
  module Types
    # A GitHub account as it appears on a comment, review, or pull request.
    Author = Data.define(:login, :avatar_url, :html_url)

    # A pull request label.
    Label = Data.define(:name, :color)

    Repo = Data.define(
      :id, :owner, :name, :full_name, :private, :description, :default_branch,
      :pushed_at, :open_issues_count, :html_url, :owner_avatar_url, :owner_type
    ) do
      # GitHub reports `owner_type` as "User" or "Organization". Only orgs have a
      # member list, so this gates the org-members half of `mentionables`.
      def organization? = owner_type == "Organization"

      def private? = !!private
    end

    PullRequest = Data.define(
      :number, :node_id, :title, :body, :state, :draft, :merged, :author,
      :head_sha, :base_sha, :head_ref, :base_ref, :created_at, :updated_at,
      :labels, :html_url, :changed_files, :additions, :deletions
    ) do
      def draft? = !!draft

      def merged? = !!merged

      def open? = state == "open"
    end

    PullRequestFile = Data.define(
      :path, :previous_path, :status, :additions, :deletions, :patch, :blob_url
    ) do
      MARKDOWN_EXTENSIONS = /\.(md|markdown|mdx)\z/i

      def markdown? = path.match?(MARKDOWN_EXTENSIONS)

      # No patch means no commentable lines at all: the file is binary, its diff
      # exceeded GitHub's size limits, or it is a pure rename. Callers must show
      # the file as uncommentable rather than treating it as "no changes".
      def patch? = patch.present?

      def renamed? = status == "renamed" && previous_path.present?

      def added? = status == "added"

      def removed? = status == "removed"

      # The path to read on the base side — a rename moves it.
      def base_path = previous_path.presence || path
    end

    # A pull request review. PENDING reviews are the viewer's unsubmitted draft
    # and carry no `submitted_at`; that absence is how we find them.
    Review = Data.define(
      :id, :node_id, :state, :body, :author, :submitted_at, :commit_id, :html_url
    ) do
      def pending? = state == "PENDING"
    end

    # One comment inside a thread. `id` is the REST id (GraphQL `databaseId`) and
    # `node_id` is the GraphQL node id; writes use the node id, REST replies use
    # the numeric id.
    ReviewComment = Data.define(
      :id, :node_id, :author, :body, :body_html, :state, :created_at, :url,
      :diff_hunk, :outdated, :viewer_can_update, :viewer_can_delete,
      :viewer_can_react, :reply_to_node_id, :reaction_groups
    ) do
      def pending? = state == "PENDING"

      def root? = reply_to_node_id.nil?
    end

    # A review thread. `line` is null once the thread is outdated, in which case
    # `original_line` plus the first comment's `diff_hunk` is all we can show.
    ReviewThread = Data.define(
      :node_id, :path, :line, :original_line, :start_line, :original_start_line,
      :diff_side, :start_diff_side, :subject_type, :is_resolved, :is_outdated,
      :resolved_by, :viewer_can_resolve, :viewer_can_unresolve, :viewer_can_reply,
      :comments
    ) do
      def resolved? = !!is_resolved

      # Two conditions, not one. GitHub sets isOutdated when newer commits moved
      # the code, but a line-level thread can also come back with a null `line`
      # while isOutdated is still false. Either way there is no line to anchor
      # to, and treating only the flag as outdated would place such a thread on
      # whatever block happens to sit at line nil. A file-level thread has no
      # line by design and is not outdated.
      def outdated? = !!is_outdated || (!file_level? && line.nil?)

      # subject_type is GraphQL-style: "LINE" or "FILE".
      def file_level? = subject_type == "FILE"

      def right_side? = diff_side == "RIGHT"

      def left_side? = diff_side == "LEFT"

      def root_comment = comments.first

      # Nil for an outdated or file-level thread — callers must not anchor those
      # to a block.
      def anchor_line = file_level? ? nil : line
    end

    # `content` is REST-style ("+1", "heart", …) even though we add and remove
    # reactions over GraphQL; Github::Client maps to and from the GraphQL enum.
    ReactionGroup = Data.define(:content, :count, :viewer_has_reacted) do
      def viewer_has_reacted? = !!viewer_has_reacted

      def any? = count.to_i.positive?
    end

    # A person who can be @-mentioned in this repository.
    Mentionable = Data.define(:login, :name, :avatar_url)

    # A repository webhook Prism registered. `url` is the callback we asked
    # GitHub to POST to, and is how we recognize our own hook among any others
    # the repository already has. The secret is write-only on GitHub's side —
    # it never comes back in a response — which is why WebhookSubscription
    # keeps its own copy.
    Hook = Data.define(:id, :url, :events, :active) do
      def active? = !!active

      def pull_request? = Array(events).include?("pull_request")
    end

    # `review_threads` returns the pull request's node id alongside the threads,
    # because every write mutation needs that id and this saves a second call.
    ReviewThreadsResult = Data.define(:pull_request_node_id, :threads)
  end
end
