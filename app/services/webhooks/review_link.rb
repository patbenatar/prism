# frozen_string_literal: true

module Webhooks
  # The canonical "review this pull request in Prism" URL, and the Markdown
  # that carries it.
  #
  # This link outlives us. It is written into a pull request description on
  # github.com, where it stays after the pull request is merged, after the
  # branch is deleted, and after we next refactor the review screen. So it is
  # built from a route helper, in exactly one place, and never by interpolating
  # strings.
  #
  # The target is `/:owner/:repo/pulls/:number/markdown` — the single page
  # that renders every renderable Markdown file in the pull request. Agreed
  # with the owner of that screen and **frozen**: it is load-bearing on their
  # side too (every "view this file" link is an anchor into it, and the old
  # per-file URL 302s to it), so a rename would fail loudly in both suites
  # rather than quietly producing dead links in old descriptions.
  #
  # That screen answers 200 with an empty state when a pull request has no
  # renderable Markdown — it never 404s. That matters here: Prism decides
  # whether to post a link from a scan taken seconds earlier, and a file can
  # be renamed out of `.md` between the scan and someone clicking. The reader
  # gets an honest page rather than an error.
  class ReviewLink
    attr_reader :owner, :repo, :number

    def initialize(owner:, repo:, number:)
      @owner = owner
      @repo = repo
      @number = number
    end

    def url
      helpers.repo_pull_markdown_url(owner: owner, repo: repo, number: number, **PublicUrl.url_options)
    end

    # One line, because it is going into someone else's writing. It says what
    # the link is, how much is behind it, and — because a bot editing a human's
    # text should sign its work — whose account made the edit.
    def markdown(file_count:, actor_login:)
      files = file_count == 1 ? "1 Markdown file" : "#{file_count} Markdown files"

      "**[Review #{files} rendered, in Prism](#{url})** — comment on paragraphs " \
        "and headings instead of diff lines.\n\n" \
        "<sub>Link added by Prism on behalf of @#{actor_login}. " \
        "Delete this block and Prism will not add it again.</sub>"
    end

    private

    # The host comes from PublicUrl, explicitly, because a background job has
    # no request to take it from and Prism sets no default_url_options — see
    # docs/webhooks.md for why.
    def helpers = Rails.application.routes.url_helpers
  end
end
