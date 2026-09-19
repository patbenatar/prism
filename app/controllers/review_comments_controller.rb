# frozen_string_literal: true

# The write path for one review comment: post it immediately or add it to the
# viewer's pending review, reply to a thread, edit or delete your own comment.
#
# GitHub is the only source of truth (PLAN.md principle 1), so every response
# re-fetches `review_threads` rather than trusting the mutation's own payload
# to still be correct once other threads and the pending-review tray are
# folded in. See PLAN.md "Phase 2 seam: file view (D) <-> commenting (E)" for
# the container ids this streams into.
class ReviewCommentsController < ApplicationController
  include GithubErrorHandling

  before_action :set_scope

  # Github::GraphQLError is here too: create_thread/add_thread_to_review go
  # over GraphQL, and docs/research/github-api.md §3.2 confirms the
  # "must be part of the diff" validation applies there exactly as it does to
  # the REST endpoint — but GraphQL failures never become LineNotCommentable
  # or Unprocessable (those are only raised from Octokit's own 422 handling),
  # so without this a validation failure here would be an unhandled 500.
  #
  # ArgumentError is here too: build_anchor hands raw params straight to
  # Review::Anchor, which raises on a bad side or a reversed range (a stale
  # page, or a tampered form) — that must become the same inline composer
  # error a 422 already produces, not a 500.
  rescue_from Github::LineNotCommentable, Github::Unprocessable, Github::RateLimited, Github::GraphQLError,
              ArgumentError, with: :handle_write_error

  # Github::NotFound/Forbidden shadow GithubErrorHandling's own full-page
  # handlers on purpose (registered after `include`, so Rails checks these
  # first): a revoked token or a deleted pull request mid-write should not
  # blow away a Turbo Stream response the way a full-page render would. Each
  # action already knows which container it was writing into, so the error
  # replaces that instead of the whole screen; a plain HTML request still
  # gets GithubErrorHandling's page.
  rescue_from Github::NotFound, Github::Forbidden, with: :handle_repo_error

  # POST .../comments
  #
  # params: path, line, side, start_line, start_side, subject_type, block_id,
  # block_text, block_start_line, block_end_line, body, commit ("single" or
  # "review").
  def create
    pull_request = github.pull_request(@owner, @repo, @number)
    anchor = build_anchor
    body = build_body(pull_request)

    thread = writer.create_thread(pull_request: pull_request, anchor: anchor, body: body, mode: params[:commit])

    render_new_thread(pull_request: pull_request, thread: thread, block_id: params[:block_id])
  end

  # POST .../comments/:id/replies — :id is the thread's root comment's REST id
  # (GitHub's own reply endpoint takes exactly that), mirroring how GitHub
  # shapes this URL. `thread_id` is the thread's GraphQL node id, submitted as
  # a hidden field by `_reply_form` because `reply_in_review` needs it and no
  # REST id maps to it.
  def reply
    pull_request = github.pull_request(@owner, @repo, @number)
    mode = ActiveModel::Type::Boolean.new.cast(params[:review]) ? "review" : "single"

    writer.reply(pull_request: pull_request, root_comment_id: params[:id],
                 thread_node_id: params[:thread_id], body: params[:body], mode: mode)

    render_thread_replace(thread_node_id: params[:thread_id])
  end

  # PATCH .../comments/:id — :id is the comment's GraphQL node id. Works on a
  # submitted comment and a pending draft alike.
  def update
    comment = github.update_comment(params[:id], body: params[:body])
    render_comment_replace(comment)
  end

  # DELETE .../comments/:id — :id is the comment's GraphQL node id. `thread_id`
  # is submitted alongside it so the response can tell whether the thread
  # emptied out (GitHub removes a thread once its last comment is deleted).
  def destroy
    github.delete_comment(params[:id])
    render_after_delete(thread_id: params[:thread_id])
  end

  private

  def set_scope
    @owner = params[:owner]
    @repo = params[:repo]
    @number = params[:number].to_i
  end

  def writer = @writer ||= Review::CommentWriter.new(github: github, owner: @owner, repo: @repo, number: @number)

  # ------------------------------------------------------------- anchors ---

  def build_anchor
    path = params[:path]
    return Review::Anchor.file(path) if params[:subject_type].to_s == "file"

    side = side_sym(params[:side])
    if params[:start_line].present?
      Review::Anchor.multi_line(path: path, start_line: params[:start_line].to_i,
                                 line: params[:line].to_i, side: side,
                                 start_side: side_sym(params[:start_side].presence || params[:side]))
    else
      Review::Anchor.line(path: path, line: params[:line].to_i, side: side)
    end
  end

  def side_sym(value) = value.to_s.downcase.presence&.to_sym || :right

  # A file-level comment is built server-side from the block's own text (sent
  # by the gutter button as data attributes and copied into hidden fields by
  # the composer) rather than trusting a client-built quote, so the format
  # matches Review::FileCommentBody exactly regardless of what the browser did.
  def build_body(pull_request)
    raw = params[:body].to_s
    return raw unless params[:subject_type].to_s == "file"

    block = Markdown::Block.new(
      id: params[:block_id], type: nil,
      start_line: params[:block_start_line].presence&.to_i || params[:block_end_line].to_i,
      end_line: params[:block_end_line].presence&.to_i || params[:block_start_line].to_i,
      html: nil, plain_text: params[:block_text].to_s,
      depth: 0, parent_id: nil, children: []
    )

    Review::FileCommentBody.call(block: block, owner: @owner, repo: @repo,
                                  head_sha: pull_request.head_sha, path: params[:path], body: raw)
  end

  # -------------------------------------------------------------- render ---

  # Fetched once per request and reused by every render_* method below, so a
  # single write only ever costs one extra read of the full thread list.
  def fresh_threads = @fresh_threads ||= github.review_threads(@owner, @repo, @number)

  # Reuses the writer's own resolved review when this request already paid
  # for one (a review-mode create/reply): otherwise this is the only read of
  # `GET .../reviews` in the request, same as before.
  def current_pending_review
    @current_pending_review ||= writer.resolved_review || github.pending_review(@owner, @repo, @number)
  end

  def thread_locals(thread, pull_request, block_id: nil)
    { thread: thread, pull_request: pull_request, pending_review: current_pending_review, block_id: block_id }
  end

  # `thread` is the mutation's own return value (create_thread/
  # add_thread_to_review already built it from the same THREAD_FIELDS +
  # COMMENT_FIELDS fragments the reviewThreads refetch uses), kept as a
  # fallback for the read-after-write race the independent review flagged
  # (M7, 2026-09-19): if the refetch does not yet contain the thread GitHub
  # just told us it created, rendering nothing and clearing the composer
  # anyway would make the reviewer's comment vanish with no explanation, even
  # though it really did post. Render whichever copy exists — the fresh one
  # when the refetch caught up, the mutation's own one otherwise — and only
  # clear the composer in the first case; the second gets an inline notice
  # instead, with the reviewer's text intact so nothing is lost from view.
  def render_new_thread(pull_request:, thread:, block_id:)
    fresh = fresh_threads.threads.find { |t| t.node_id == thread.node_id }
    rendered_thread = fresh || thread

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          new_thread_stream(rendered_thread, pull_request, block_id: block_id),
          composer_stream_after_create(pull_request, block_id: block_id, delivered: fresh.present?),
          pending_tray_stream(pull_request)
        ]
      end
      format.html { redirect_to file_path, notice: "Comment posted." }
    end
  end

  # A file-level thread (L1, independent review 2026-09-19) belongs in
  # `#file_threads` at the top of the page, same as a full page load would
  # place it (Review::BlockMapper buckets subject_type FILE there, never
  # under a block) — appending it into `threads_<block_id>` instead would
  # make it jump to the top the next time the page loads.
  def new_thread_stream(thread, pull_request, block_id:)
    locals = thread_locals(thread, pull_request, block_id: block_id)
    return turbo_stream.prepend("file_threads", partial: "review_comments/thread", locals: locals) if thread.file_level?

    turbo_stream.append("threads_#{block_id}", partial: "review_comments/thread", locals: locals)
  end

  def composer_stream_after_create(pull_request, block_id:, delivered:)
    return turbo_stream.update("composer_#{block_id}", "") if delivered

    turbo_stream.replace(
      "composer_#{block_id}", partial: "review_comments/composer_form",
      locals: composer_error_locals(pull_request, current_pending_review,
                                     "Posted to GitHub, but it hasn't appeared yet — reload to see it.")
    )
  end

  def render_thread_replace(thread_node_id:)
    pull_request = github.pull_request(@owner, @repo, @number)
    thread = fresh_threads.threads.find { |t| t.node_id == thread_node_id }

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [ thread_stream(thread_node_id, thread, pull_request), pending_tray_stream(pull_request) ]
      end
      format.html { redirect_to file_path, notice: "Reply posted." }
    end
  end

  def render_comment_replace(comment)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace("comment_#{comment.node_id}",
                                                   partial: "review_comments/comment",
                                                   locals: { comment: comment, thread_id: params[:thread_id] })
      end
      format.html { redirect_to file_path, notice: "Comment updated." }
    end
  end

  def render_after_delete(thread_id:)
    pull_request = github.pull_request(@owner, @repo, @number)
    thread = thread_id.present? ? fresh_threads.threads.find { |t| t.node_id == thread_id } : nil

    respond_to do |format|
      format.turbo_stream do
        streams = [ pending_tray_stream(pull_request) ]
        streams << thread_stream(thread_id, thread, pull_request) if thread_id.present?
        render turbo_stream: streams
      end
      format.html { redirect_to file_path, notice: "Comment deleted." }
    end
  end

  # A thread that no longer exists (its last comment was just deleted, or it
  # was outdated out of the query) is removed rather than replaced.
  def thread_stream(thread_node_id, thread, pull_request)
    return turbo_stream.remove("thread_#{thread_node_id}") if thread.nil?

    turbo_stream.replace("thread_#{thread_node_id}",
                          partial: "review_comments/thread", locals: thread_locals(thread, pull_request))
  end

  def pending_tray_stream(pull_request)
    pending_count = fresh_threads.threads.flat_map(&:comments).count(&:pending?)

    turbo_stream.replace("pending_tray",
                          partial: "reviews/pending_tray",
                          locals: { pull_request: pull_request, pending_review: current_pending_review,
                                    pending_count: pending_count })
  end

  def file_path
    repo_pull_file_path(owner: @owner, repo: @repo, number: @number, path: params[:path])
  end

  # ---------------------------------------------------------------- errors ---

  def handle_write_error(error)
    case action_name
    when "create"
      render_composer_error(error)
    else
      message = user_message(error)
      respond_to do |format|
        format.turbo_stream { redirect_to file_path, alert: message }
        format.html { redirect_to file_path, alert: message }
      end
    end
  end

  # A GraphQLError's own message is GitHub's raw validation text, not the
  # friendly wording Github::LineNotCommentable carries — recognize the one
  # case that matters (docs/research/github-api.md §3.2) and borrow it.
  #
  # ArgumentError (a bad anchor param) has no user_message at all — its own
  # #message is what Review::Anchor raised, plain but truthful, and there is
  # no GitHub wording to borrow instead.
  def user_message(error)
    if error.is_a?(Github::GraphQLError)
      return Github::LineNotCommentable.new.user_message if error.message.match?(/must be part of the diff/i)

      return error.user_message
    end

    error.respond_to?(:user_message) ? error.user_message : error.message
  end

  # Registered after `include GithubErrorHandling`, so this wins for
  # Github::NotFound/Forbidden. Each write action already knows which
  # container it was writing into; replace that instead of the whole page for
  # a Turbo Stream request, and fall back to the full explanation page
  # (`shared/not_found` / `shared/forbidden`) for a plain HTML one.
  def handle_repo_error(error)
    respond_to do |format|
      format.turbo_stream { render_repo_error_stream(error) }
      format.html { render_full_repo_error_page(error) }
    end
  end

  def render_repo_error_stream(error)
    target = repo_error_target
    return redirect_to(file_path, alert: error.user_message) if target.nil?

    render turbo_stream: turbo_stream.replace(
      target, partial: "review_comments/inline_error", locals: { message: error.user_message }
    ), status: error.is_a?(Github::Forbidden) ? :forbidden : :not_found
  end

  # Whichever container each action already knows it was writing into —
  # nil means there is nothing specific to replace, so the caller redirects.
  def repo_error_target
    case action_name
    when "create" then "composer_#{params[:block_id]}"
    when "reply", "destroy" then "thread_#{params[:thread_id]}" if params[:thread_id].present?
    when "update" then "comment_#{params[:id]}"
    end
  end

  def render_full_repo_error_page(error)
    error.is_a?(Github::Forbidden) ? github_forbidden(error) : github_not_found(error)
  end

  def render_composer_error(error)
    pull_request = github.pull_request(@owner, @repo, @number)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "composer_#{params[:block_id]}",
          partial: "review_comments/composer_form",
          locals: composer_error_locals(pull_request, current_pending_review, user_message(error))
        ), status: :unprocessable_content
      end
      format.html { redirect_to file_path, alert: user_message(error) }
    end
  end

  def composer_error_locals(pull_request, pending_review, message)
    {
      pull_request: pull_request, path: params[:path], pending_review: pending_review,
      block_id: params[:block_id], subject_type: params[:subject_type].presence || "line",
      line: params[:line], side: params[:side], start_line: params[:start_line], start_side: params[:start_side],
      uncommentable_reason: params[:uncommentable_reason],
      body: params[:body], block_text: params[:block_text],
      block_start_line: params[:block_start_line], block_end_line: params[:block_end_line],
      error: message
    }
  end
end
