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

  rescue_from Github::Unconfirmed, with: :handle_unconfirmed

  # POST .../threads/:id/resolve — :id is the thread's GraphQL node id.
  def resolve
    render_thread(github.resolve_thread(params[:id]))
  end

  # POST .../threads/:id/unresolve
  def unresolve
    render_thread(github.unresolve_thread(params[:id]))
  end

  private

  def set_scope
    @owner = params[:owner]
    @repo = params[:repo]
    @number = params[:number].to_i
  end

  # `thread` is resolve_thread/unresolve_thread's own returned payload — the
  # same THREAD_FIELDS + COMMENT_FIELDS fragments a reviewThreads query would
  # return — so this renders it directly with no refetch of the thread list
  # at all (2026-09-19, "saving a comment feels slow": the heaviest call in
  # this request was exactly that refetch). `pending_review` is still a real
  # `GET .../reviews` — needed for the reply form's button label, and cheap
  # enough on its own (~200ms) not to be worth the same trick create's
  # composer plays with hidden fields, since resolve/unresolve have no
  # composer to carry that state through.
  def render_thread(thread)
    pending_review = github.pending_review(@owner, @repo, @number)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "thread_#{thread.node_id}",
          partial: "review_comments/thread",
          locals: { thread: thread, pull_request: nil, pending_review: pending_review, block_id: nil }
        )
      end
      format.html { redirect_to fallback_path(thread), notice: "Thread updated." }
    end
  end

  # No specific file to go back to without a thread (e.g. it was resolved and
  # is now gone), so fall back to the PR overview.
  def fallback_path(thread)
    return repo_pull_path(owner: @owner, repo: @repo, number: @number) if thread.nil?

    repo_pull_markdown_path(owner: @owner, repo: @repo, number: @number,
                            anchor: Review::Page.file_key(thread.path))
  end

  def handle_error(error)
    respond_to do |format|
      format.turbo_stream { redirect_to repo_pull_path(owner: @owner, repo: @repo, number: @number), alert: error.user_message }
      format.html { redirect_to repo_pull_path(owner: @owner, repo: @repo, number: @number), alert: error.user_message }
    end
  end

  # GitHub accepted the mutation and answered with nothing, so we cannot say
  # whether it happened (Github::Unconfirmed, raised by
  # Github::Client#confirmed!). Reloading the page is the honest answer: it
  # shows the thread as GitHub has it, and the notice says we could not
  # confirm rather than claiming a failure that may not have occurred.
  def handle_unconfirmed(_error)
    path = repo_pull_path(owner: @owner, repo: @repo, number: @number)
    notice = "GitHub didn't confirm that, so it may or may not have gone through. " \
             "This is the conversation as GitHub has it now."

    respond_to do |format|
      format.turbo_stream { redirect_to path, notice: notice }
      format.html { redirect_to path, notice: notice }
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
