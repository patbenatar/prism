# frozen_string_literal: true

# Resolve / unresolve a thread. GraphQL-only (PLAN.md "Github::Client
# interface") — there is no REST equivalent.
class ReviewThreadsController < ApplicationController
  include GithubErrorHandling

  before_action :set_scope

  # Github::GraphQLError too: resolve/unresolve are GraphQL-only, so a
  # validation failure there never becomes Github::Unprocessable (that class
  # is only raised from Octokit's REST 422 handling).
  rescue_from Github::Unprocessable, Github::RateLimited, Github::GraphQLError, with: :handle_error

  # Registered after `include GithubErrorHandling`, so this wins for
  # Github::NotFound/Forbidden: both actions already know the thread's node
  # id, so a Turbo Stream request gets that thread replaced with an inline
  # explanation instead of the whole page GithubErrorHandling would render.
  rescue_from Github::NotFound, Github::Forbidden, with: :handle_repo_error

  # POST .../threads/:id/resolve — :id is the thread's GraphQL node id.
  def resolve
    github.resolve_thread(params[:id])
    render_thread(params[:id])
  end

  # POST .../threads/:id/unresolve
  def unresolve
    github.unresolve_thread(params[:id])
    render_thread(params[:id])
  end

  private

  def set_scope
    @owner = params[:owner]
    @repo = params[:repo]
    @number = params[:number].to_i
  end

  def render_thread(thread_node_id)
    pull_request = github.pull_request(@owner, @repo, @number)
    result = github.review_threads(@owner, @repo, @number)
    thread = result.threads.find { |t| t.node_id == thread_node_id }
    pending_review = github.pending_review(@owner, @repo, @number)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "thread_#{thread_node_id}",
          partial: "review_comments/thread",
          locals: { thread: thread, pull_request: pull_request, pending_review: pending_review, block_id: nil }
        )
      end
      format.html { redirect_to fallback_path(thread), notice: "Thread updated." }
    end
  end

  # No specific file to go back to without a thread (e.g. it was resolved and
  # is now gone), so fall back to the PR overview.
  def fallback_path(thread)
    return repo_pull_path(owner: @owner, repo: @repo, number: @number) if thread.nil?

    repo_pull_file_path(owner: @owner, repo: @repo, number: @number, path: thread.path)
  end

  def handle_error(error)
    respond_to do |format|
      format.turbo_stream { redirect_to repo_pull_path(owner: @owner, repo: @repo, number: @number), alert: error.user_message }
      format.html { redirect_to repo_pull_path(owner: @owner, repo: @repo, number: @number), alert: error.user_message }
    end
  end

  def handle_repo_error(error)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "thread_#{params[:id]}", partial: "review_comments/inline_error", locals: { message: error.user_message }
        ), status: error.is_a?(Github::Forbidden) ? :forbidden : :not_found
      end
      format.html { error.is_a?(Github::Forbidden) ? github_forbidden(error) : github_not_found(error) }
    end
  end
end
