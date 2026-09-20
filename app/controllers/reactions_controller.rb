# frozen_string_literal: true

# Add / remove a reaction on a review comment, entirely over GraphQL
# (docs/research/github-api.md §3.6 recommends this: one call each way, no
# `reaction_id` lookup, and the mutation hands back `viewerHasReacted` so the
# toggle state renders without a second request).
#
# `:reaction_id` in the destroy route is GitHub's REST shape but unused here —
# the emoji comes from `content`, submitted as a form field on both actions so
# a DELETE (which browsers can't carry a body for outside a real form POST)
# still has it.
class ReactionsController < ApplicationController
  include GithubErrorHandling

  CONTENTS = %w[+1 -1 laugh confused heart hooray rocket eyes].freeze

  before_action :set_scope

  # Github::GraphQLError too: add/remove reaction are GraphQL-only, so a
  # validation failure there never becomes Github::Unprocessable (that class
  # is only raised from Octokit's REST 422 handling).
  rescue_from Github::Unprocessable, Github::RateLimited, Github::GraphQLError, with: :handle_error

  # Registered after `include GithubErrorHandling`, so this wins for
  # Github::NotFound/Forbidden: both actions already know the comment's node
  # id, so a Turbo Stream request gets that comment replaced with an inline
  # explanation instead of the whole page GithubErrorHandling would render.
  rescue_from Github::NotFound, Github::Forbidden, with: :handle_repo_error

  # POST .../comments/:id/reactions — :id is the comment's GraphQL node id.
  def create
    comment = github.add_reaction(params[:id], content: content_param)
    render_comment(comment)
  end

  # DELETE .../comments/:id/reactions/:reaction_id
  def destroy
    comment = github.remove_reaction(params[:id], content: content_param)
    render_comment(comment)
  end

  private

  def set_scope
    @owner = params[:owner]
    @repo = params[:repo]
    @number = params[:number].to_i
  end

  def content_param
    CONTENTS.include?(params[:content]) ? params[:content] : "+1"
  end

  def render_comment(comment)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "comment_#{comment.node_id}",
          partial: "review_comments/comment",
          locals: { comment: comment, thread_id: params[:thread_id] }
        )
      end
      format.html { redirect_to file_path, notice: "Reaction updated." }
    end
  end

  # The Markdown tab, anchored at the file this reaction lives in. The old
  # per-file route still 302s here, but pointing at the destination directly
  # saves the no-JS reviewer a redirect.
  def file_path
    repo_pull_markdown_path(owner: @owner, repo: @repo, number: @number,
                            anchor: Review::Page.file_key(params[:path]))
  end

  def handle_error(error)
    respond_to do |format|
      format.turbo_stream { redirect_to file_path, alert: error.user_message }
      format.html { redirect_to file_path, alert: error.user_message }
    end
  end

  def handle_repo_error(error)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "comment_#{params[:id]}", partial: "review_comments/inline_error", locals: { message: error.user_message }
        ), status: error.is_a?(Github::Forbidden) ? :forbidden : :not_found
      end
      format.html { error.is_a?(Github::Forbidden) ? github_forbidden(error) : github_not_found(error) }
    end
  end
end
