# frozen_string_literal: true

# The write path for one review comment: post it immediately or add it to the
# viewer's pending review, reply to a thread, edit or delete your own comment.
#
# GitHub is the only source of truth (PLAN.md principle 1) — but that does
# not mean re-fetching everything on every write. `create` and `reply` both
# render straight from their own mutation's returned payload rather than
# re-querying `reviewThreads` for the whole pull request (up to 50 threads x
# 100 comments) just to find or rebuild something they already have in hand;
# the mutations build their payloads from the exact same GraphQL fragments
# the query would use, so neither is a lesser copy, and the pending-review
# tray after either one is rendered from what the page/composer already knew
# (see pending_review_from_client) rather than a second `GET .../reviews`.
# `reviewThreads` was the heaviest call in the request and its removal from
# both actions is most of the round-trip-count fix requested 2026-09-19
# ("saving a comment feels slow"). `update`/reactions were already free of
# it (their own mutations return everything needed); `destroy` still
# refetches, because deleting a comment tells you nothing about whether the
# thread it was in still exists. See PLAN.md "Phase 2 seam: file view (D)
# <-> commenting (E)" for the container ids this streams into.
class ReviewCommentsController < ApplicationController
  include GithubErrorHandling

  # Said when GitHub joined a comment to a review we did not know was open —
  # see joined_review_unasked?.
  JOINED_REVIEW_NOTICE = "Your review was already in progress, so this joined it."

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

    comment = writer.reply(pull_request: pull_request, root_comment_id: params[:id],
                            thread_node_id: params[:thread_id], body: params[:body], mode: mode)

    render_new_reply(comment: comment, thread_id: params[:thread_id], pull_request: pull_request, mode: mode)
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

  # `thread` is the mutation's own return value — create_thread/
  # add_thread_to_review already build it from the same THREAD_FIELDS +
  # COMMENT_FIELDS fragments a reviewThreads query would use, so it is
  # rendered directly with no refetch of any kind: no reviewThreads (was the
  # heaviest call in the request) and no `GET .../reviews` either (the tray's
  # two facts — whether a pending review exists, and how many comments are
  # pending — come from `pending_review_from_client`/params, below). This also
  # means there is no second fetch to lag behind the mutation, so the M7
  # read-after-write race the independent review flagged (2026-09-19) cannot
  # happen here any more; it was only ever a risk of refetching in the first
  # place.
  def render_new_thread(pull_request:, thread:, block_id:)
    joined_unasked = joined_review_unasked?(thread)
    flash.now[:notice] = JOINED_REVIEW_NOTICE if joined_unasked

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          new_thread_stream(thread, block_id: block_id,
                             pending_review: joined_unasked ? current_pending_review : pending_review_from_client),
          turbo_stream.update("composer_#{block_id}", ""),
          tray_stream_after_create(pull_request, joined_unasked: joined_unasked),
          # Always, not only when there is something to say: an empty render
          # clears whatever notice the last write left on the page.
          turbo_stream.update("flash", partial: "shared/flash")
        ]
      end
      format.html do
        redirect_to file_path, notice: joined_unasked ? JOINED_REVIEW_NOTICE : "Comment posted."
      end
    end
  end

  # GitHub does not refuse a "single" comment while the viewer already has a
  # pending review open — it silently attaches it to that review and answers
  # with the comment in state PENDING. So the reviewer asks for a posted
  # comment and gets a draft, and nothing in the request says so except the
  # state on the way back.
  #
  # This looks redundant beside the UI rule that hides "Add single comment"
  # while a review is open (DESIGN.md §8), and it is the half of that rule
  # which cannot live on the client: a page that went stale — a review opened
  # in another tab, or after this one loaded — still asks for a single
  # comment, and this is the only moment we find out. Reported rather than
  # prevented, because by now it has already happened; the comment is safe,
  # it is just a draft.
  def joined_review_unasked?(thread)
    !review_mode?(params[:commit]) && thread.comments.any?(&:pending?)
  end

  # The ordinary path derives the tray from what the page already knew, with
  # no GitHub call. When the page turned out to be wrong about the review,
  # those same hidden fields are wrong too — they carried no review and a
  # count of zero, while the real one may already hold drafts from wherever
  # it was opened — so that one rare branch re-reads instead of guessing. A
  # tray that says "1 pending comment" with no Submit button would be a fresh
  # inaccuracy inside the one message whose point is to be accurate.
  def tray_stream_after_create(pull_request, joined_unasked:)
    return pending_tray_stream(pull_request) if joined_unasked

    pending_tray_stream_from_client(pull_request, joined_review: review_mode?(params[:commit]))
  end

  # A file-level thread (L1, independent review 2026-09-19) belongs at the top
  # of its own file's section, same as a full page load would place it
  # (Review::BlockMapper buckets subject_type FILE there, never under a
  # block) — appending it into `threads_<block_id>` instead would make it jump
  # the next time the page loads. The container is per file now that the
  # Markdown tab holds every file at once, so the target is keyed by path.
  #
  # `pull_request` is nil here on purpose: `_thread.html.erb` never reads it
  # (every URL it builds comes from `params[:owner]`/`repo`/`number`), so
  # there is nothing to fetch just to satisfy an unused local.
  def new_thread_stream(thread, block_id:, pending_review:)
    locals = { thread: thread, pull_request: nil, pending_review: pending_review, block_id: block_id }

    if thread.file_level?
      return turbo_stream.prepend(helpers.file_threads_dom_id(params[:path]),
                                   partial: "review_comments/thread", locals: locals)
    end

    turbo_stream.append("threads_#{block_id}", partial: "review_comments/thread", locals: locals)
  end

  # `comment` is reply/reply_in_review's own returned payload — the same
  # COMMENT_FIELDS fragment a reviewThreads query would return for it — so
  # this appends it straight into the thread's own comments container
  # (`thread_comments_<id>`, see _thread.html.erb) instead of refetching
  # reviewThreads to rebuild the whole thread just to add one comment to it.
  def render_new_reply(comment:, thread_id:, pull_request:, mode:)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.append("thread_comments_#{thread_id}",
                               partial: "review_comments/comment",
                               locals: { comment: comment, thread_id: thread_id }),
          pending_tray_stream_from_client(pull_request, joined_review: review_mode?(mode))
        ]
      end
      format.html { redirect_to file_path, notice: "Reply posted." }
    end
  end

  # The pending review this request already knows about without asking
  # GitHub again: `writer.resolved_review` if this very write found or opened
  # one in review mode (ensure_pending_review's own `GET .../reviews` already
  # paid for this), otherwise whatever the page already knew when its form
  # was rendered (single mode, or review mode with no review touched —
  # carried through as hidden fields on both the composer and every open
  # reply form, kept current on both by `pending-review:changed`; see
  # composer_controller.js). A reconstructed Review is enough:
  # `_thread.html.erb`/`_reply_form.html.erb` only ever read
  # `.node_id`/`.id`/`.present?` off it, never its body or author.
  def pending_review_from_client
    writer.resolved_review || pending_review_from_params
  end

  def pending_review_from_params
    return nil if params[:pending_review_node_id].blank?

    Github::Types::Review.new(
      id: params[:pending_review_id], node_id: params[:pending_review_node_id],
      state: "PENDING", body: nil, author: nil, submitted_at: nil, commit_id: nil, html_url: nil
    )
  end

  # No refetch for the count either: the form carried the count it last knew
  # (also kept current by pending-review:changed) as a hidden field, and the
  # only way *this* request could have changed it is by adding a draft to the
  # review itself — which only happens in review mode.
  def pending_tray_stream_from_client(pull_request, joined_review:)
    prior_count = params[:pending_count].to_i
    count = joined_review ? prior_count + 1 : prior_count

    turbo_stream.replace("pending_tray",
                          partial: "reviews/pending_tray",
                          locals: { pull_request: pull_request, pending_review: pending_review_from_client,
                                    pending_count: count })
  end

  def review_mode?(mode) = mode.to_s == "review"

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

  # Where a plain HTML (no-JS, or failed-Turbo) write goes back to. The review
  # screen is one page per pull request now, so this is that page anchored at
  # the file the comment was on rather than a screen of its own.
  def file_path
    repo_pull_markdown_path(owner: @owner, repo: @repo, number: @number,
                            anchor: Review::Page.file_key(params[:path]))
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

  # `composer_<block_id>` is D's own empty slot div — its content, not itself,
  # is what a successful open() or a server render fills in, so replacing it
  # outright would discard the id the JS controller looks it up by on every
  # later `document.getElementById` call, leaving the composer permanently
  # unreachable at that block for the rest of the page's life. `thread_<id>`
  # and `comment_<id>`, by contrast, are partials that declare that same id
  # on their own root (`_thread.html.erb`, `shared/_comment_card.html.erb`
  # via `_comment.html.erb`), so replacing them re-establishes it and is
  # fine.
  def render_repo_error_stream(error)
    target = repo_error_target
    return redirect_to(file_path, alert: error.user_message) if target.nil?

    action = target.start_with?("composer_") ? :update : :replace
    render turbo_stream: turbo_stream.public_send(
      action, target, partial: "review_comments/inline_error", locals: { message: error.user_message }
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

  # Only ever reached from create's error branch (see handle_write_error), so
  # this uses the same no-refetch pending_review_from_client the success path
  # does, not current_pending_review.
  #
  # `update`, not `replace`: `composer_<block_id>` is D's own empty slot div,
  # and `_composer_form.html.erb`'s root carries no id of its own (by
  # design — the normal open() path inserts it as a *child* of that div, the
  # same way `container.appendChild(fragment)` does in composer_controller.js).
  # A `replace` here would swap the slot itself out for a div with no id,
  # leaving the composer unreachable by `document.getElementById` for the
  # rest of the page's life — caught by a system test exercising this exact
  # path in a real browser (2026-09-19).
  def render_composer_error(error)
    pull_request = github.pull_request(@owner, @repo, @number)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.update(
          "composer_#{params[:block_id]}",
          partial: "review_comments/composer_form",
          locals: composer_error_locals(pull_request, pending_review_from_client, user_message(error))
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
      # Preserved from the failed submission's own hidden field, not reset to
      # 0 — otherwise a retry that succeeds after this error would increment
      # from the wrong base and under-count the tray.
      pending_count: params[:pending_count],
      error: message
    }
  end
end
