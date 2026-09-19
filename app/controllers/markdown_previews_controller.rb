# frozen_string_literal: true

# Renders a comment body through GitHub's own `/markdown` endpoint (mode gfm)
# for the composer's Write/Preview tab, so @-mentions and #123 references
# preview exactly as they will look once posted. See
# docs/research/github-api.md §2.11 and PLAN.md caching rules (cached by
# SHA256(body+context) for a day).
class MarkdownPreviewsController < ApplicationController
  # Deliberately not Github::Error as a whole, and deliberately not
  # Github::Unauthorized by name: Authentication's own
  # `rescue_from Github::Unauthorized, with: :handle_revoked_token` must stay
  # in charge of a dead token (clearing it and signing out), which a blanket
  # `rescue_from Github::Error` here would shadow — the preview would show a
  # small error fragment forever while the revoked token sat in the database
  # waiting to be retried. Mirrors MentionablesController.
  rescue_from Github::Forbidden, Github::NotFound, Github::RateLimited, Github::GraphQLError,
              Github::Unavailable, Github::Unprocessable, with: :render_error

  # POST .../markdown/preview — params: text
  def create
    owner = params[:owner]
    repo = params[:repo]

    html = github.render_markdown(params[:text].to_s, context: "#{owner}/#{repo}")

    render html: helpers.github_html(html) || "".html_safe, layout: false
  end

  private

  def render_error(error)
    message = ERB::Util.html_escape(error.user_message)
    render html: %(<p class="text-xs text-removed">#{message}</p>).html_safe, layout: false
  end
end
