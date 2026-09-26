import { Controller } from "@hotwired/stimulus"

// The three icons the optimistic card reserves room for, kept byte-identical
// to `review_comments/_comment` and `shared/_comment_card` — the point of the
// provisional card is that it is the same shape as what replaces it, and an
// icon drawn a pixel differently is a seam in exactly the transition this
// exists to smooth.
const PENCIL_PATHS =
  '<path d="M11.2 2.6a1.7 1.7 0 0 1 2.4 2.4L6.1 12.5l-3.1.9.9-3.1 7.3-7.7Z" /><path d="m10.3 3.6 2.4 2.4" />'
const BIN_PATHS =
  '<path d="M3 4.5h10" /><path d="M6.3 4.5V3.2h3.4v1.3" /><path d="m4.6 4.5.6 8.3h5.6l.6-8.3" />'
const EXTERNAL_PATHS =
  '<path d="M9.5 3h3.5v3.5" /><path d="M13 3 7.8 8.2" /><path d="M11.5 9.8V13H3V4.5h3.2" />'
const REACTION_PATHS =
  '<path d="M13.4 7.3a5.7 5.7 0 1 1-4.7-4.7" /><path d="M5.6 9.4a3 3 0 0 0 4.3 0" />' +
  '<path d="M5.9 6.4h.01M9.7 6.4h.01" /><path d="M12.4 1.9v3.2M14 3.5h-3.2" />'

// Opens/closes the comment composer under a block's gutter "+", per
// PLAN.md "Phase 2 seam: file view (D) <-> commenting (E)".
//
// Lives on the file view's <main> (data-controller="composer …"), which D
// renders with plain data attributes (not Stimulus `-value` attributes) —
// see the seam's `data-composer-template-id`, `-pending-review-node-id`,
// `-pending-review-id`, `-viewer-login`, `-viewer-avatar`, etc. Read
// directly off `this.element.dataset` rather than `static values` so this
// controller does not depend on D switching those to the Stimulus value
// convention.
//
// The gutter button itself (also D's) carries plain data attributes too, so
// D never needs this controller's JS loaded to render a valid page —
// `data-block-id`, `data-block-text`, `data-start-line`, `data-end-line`,
// `data-commentable`, `data-uncommentable-reason`, `data-anchor` (the
// Review::Anchor#to_rest JSON, or "null").
export default class extends Controller {
  connect() {
    this.openBlockId = null
    this.provisionalIds = []
    // Seeded from the seam's own data attributes (the server's knowledge at
    // page load); pending-review:changed keeps nodeId/id/count current
    // after that — see syncPendingReview.
    this.pendingReviewNodeId = this.element.dataset.composerPendingReviewNodeId || null
    this.pendingReviewId = this.element.dataset.composerPendingReviewId || null
    this.pendingCount = 0
    this.boundSyncPendingReview = this.syncPendingReview.bind(this)
    window.addEventListener("pending-review:changed", this.boundSyncPendingReview)
  }

  disconnect() {
    window.removeEventListener("pending-review:changed", this.boundSyncPendingReview)
  }

  // data-action="composer#open" on every gutter "+" button.
  //
  // Whether this click should open or close is decided from the container's
  // *actual* DOM content, not from `openBlockId` alone: a successful submit
  // clears `composer_<id>` via a server-rendered Turbo Stream
  // (`ReviewCommentsController#render_new_thread`), which this controller
  // has no callback for, so `openBlockId` would otherwise still say "open"
  // for a composer the server just emptied — making the next click on the
  // same block's "+" look like a close instead of a reopen.
  //
  // "Open" means a composer is in the slot, not that the slot has any child
  // at all. The server can also put something else there — it used to put a
  // bare error card in on a 404/403 — and reading that as "open" made the
  // next "+" a close, so reaching the composer again took two clicks. The
  // server now hands back the whole composer instead (with the reviewer's
  // text in it), but the question this asks is the one it always meant.
  open(event) {
    const button = event.currentTarget
    const blockId = button.dataset.blockId
    if (!blockId) return

    const container = document.getElementById(`composer_${blockId}`)
    if (!container) return

    const alreadyOpenHere = container.querySelector('[data-composer-target="form"]') !== null

    if (this.openBlockId && this.openBlockId !== blockId) this.closeBlock(this.openBlockId)
    if (alreadyOpenHere) return this.closeBlock(blockId) // toggle closed

    const template = document.getElementById(this.templateId)
    if (!template) return

    const fragment = template.content.cloneNode(true)
    this.fillFields(fragment, button)

    container.innerHTML = ""
    container.appendChild(fragment)
    this.openBlockId = blockId

    const textarea = container.querySelector('[data-composer-target="textarea"]')
    if (textarea) {
      textarea.focus()
      this.autosize({ target: textarea })
    }
  }

  close(event) {
    event?.preventDefault?.()
    if (this.openBlockId) this.closeBlock(this.openBlockId)
  }

  closeBlock(blockId) {
    const container = document.getElementById(`composer_${blockId}`)
    if (container) container.innerHTML = ""
    if (this.openBlockId === blockId) this.openBlockId = null
  }

  // data-action="keydown->composer#keydown" on the block composer's own
  // textarea. Escape belongs to the block composer alone — it closes
  // `openBlockId` — which is why the reply and edit forms bind
  // `composer#submitOnEnter` below instead of this.
  keydown(event) {
    if (event.key === "Escape") {
      this.close(event)
      return
    }

    this.submitOnEnter(event)
  }

  // data-action="keydown->composer#submitOnEnter" on the reply and edit
  // textareas. Cmd/Ctrl+Enter submits all three editors, the way it does on
  // GitHub — before this it only worked in the block composer, and inserted a
  // newline in a reply or an edit.
  submitOnEnter(event) {
    const submitting = (event.metaKey || event.ctrlKey) && event.key === "Enter"
    if (!submitting) return

    const form = event.target.closest("form")
    const button = form && this.visibleSubmitButton(form)
    // Nothing the reviewer could have clicked, so nothing the keyboard should
    // send either — a thread they may not reply to while a review is open
    // still renders its box, with both buttons gone.
    if (!button) return

    event.preventDefault()
    form.requestSubmit(button)
  }

  // The button the keyboard stands in for: the one the reviewer can actually
  // see. While a review is open the single-comment and immediate-reply
  // buttons are hidden, because GitHub folds both into the review anyway
  // (see applyReviewOnly), so submitting one would send exactly the request
  // the UI has stopped offering. The edit form has no composer targets at
  // all — its single "Save" is the fallback.
  visibleSubmitButton(form) {
    const preferred = ["singleButton", "replySingleButton", "reviewButton", "replyReviewButton"]
    for (const name of preferred) {
      const button = form.querySelector(`[data-composer-target="${name}"]:not([hidden])`)
      if (button) return button
    }

    return form.querySelector('[type="submit"]:not([hidden])')
  }

  // data-action="input->composer#autosize" — generic, used by the composer,
  // reply and edit textareas alike.
  autosize(event) {
    const el = event.target
    el.style.height = "auto"
    el.style.height = `${el.scrollHeight}px`
  }

  // window:pending-review:changed — dispatched by pending_review_controller
  // every time the tray is replaced, so an open composer's "Start a
  // review"/"Add review comment" label, and the next composer's hidden
  // pending_review_node_id/pending_review_id/pending_count fields, stay
  // correct without a reload.
  syncPendingReview(event) {
    this.pendingReviewNodeId = event.detail?.pendingReviewNodeId || null
    this.pendingReviewId = event.detail?.pendingReviewId || null
    this.pendingCount = event.detail?.pendingCount || 0

    this.element.querySelectorAll('[data-composer-target="reviewButton"]').forEach((button) => {
      button.textContent = this.pendingReviewNodeId ? "Add review comment" : "Start a review"
    })
    // Every open thread's static reply form, not only a cloned composer —
    // reply_form.html.erb reuses these same target names so its own hidden
    // fields (read by ReviewCommentsController#reply, no refetch needed) and
    // its "Add to review"/"Start a review with this reply" button stay
    // correct without a reload too.
    this.element.querySelectorAll('[data-composer-target="replyReviewButton"]').forEach((button) => {
      button.textContent = this.pendingReviewNodeId ? "Add to review" : "Start a review with this reply"
    })
    this.element.querySelectorAll('[data-composer-target="pendingReviewNodeId"]').forEach((field) => {
      field.value = this.pendingReviewNodeId || ""
    })
    this.element.querySelectorAll('[data-composer-target="pendingReviewId"]').forEach((field) => {
      field.value = this.pendingReviewId || ""
    })
    this.element.querySelectorAll('[data-composer-target="pendingCount"]').forEach((field) => {
      field.value = this.pendingCount
    })
    this.applyReviewOnly(this.element)
  }

  // GitHub refuses both standalone writes while a review is open: a "single"
  // comment comes back as a PENDING draft on that review, and an immediate
  // reply 422s with "user_id can only have one pending review per pull
  // request". So while one is open those two buttons are removed and a line
  // takes their place. Called with the whole page when the state changes
  // under composers that are already open, and with a freshly cloned
  // fragment before it is inserted.
  applyReviewOnly(root) {
    const reviewOnly = !!this.pendingReviewNodeId

    root
      .querySelectorAll('[data-composer-target="singleButton"], [data-composer-target="replySingleButton"]')
      .forEach((button) => {
        button.hidden = reviewOnly
      })
    root.querySelectorAll('[data-composer-target="reviewOnlyNote"]').forEach((note) => {
      note.hidden = !reviewOnly
    })
  }

  // data-action="turbo:submit-start->composer#showProvisional" on the
  // composer's own form. Optimistic rendering (2026-09-19, "saving a
  // comment feels slow"): a GitHub round trip is 200-400ms even after
  // ReviewCommentsController#create stopped refetching, so this shows the
  // comment immediately rather than waiting for the response — a card with
  // the reviewer's own words and a muted "Sending…" state, inserted where
  // the real thread will land (appended under the block, or prepended into
  // #file_threads for a file-level comment). It is removed unconditionally
  // on submit-end (success or failure) by id, so a failed submit — which
  // re-renders the composer with the error instead of the thread — leaves
  // no orphan behind.
  showProvisional(event) {
    const form = event.target
    const blockId = form.querySelector('[data-composer-target="blockId"]')?.value
    const subjectType = form.querySelector('[data-composer-target="subjectType"]')?.value
    const body = form.querySelector('[data-composer-target="textarea"]')?.value?.trim()
    if (!blockId || !body) return

    const container =
      subjectType === "file" ? this.fileThreadsContainer(form) : document.getElementById(`threads_${blockId}`)
    if (!container) return

    const card = this.buildProvisionalCard(body, this.submittedIntoReview(event))
    if (subjectType === "file") {
      container.prepend(card)
    } else {
      container.appendChild(card)
    }
    this.provisionalIds.push(card.id)

    // Visually clear the composer right away rather than emptying it —
    // emptying it would remove the very form this submit-start handler is
    // attached to while the request it just started is still in flight.
    const composerContainer = document.getElementById(`composer_${blockId}`)
    if (composerContainer) composerContainer.classList.add("hidden")
  }

  // data-action="turbo:submit-end->composer#removeProvisional" — fires once
  // the response (success or failure) has already been processed, so the
  // real thread (or the re-rendered composer, on failure) is already in the
  // DOM by the time this runs.
  removeProvisional() {
    this.provisionalIds.forEach((id) => document.getElementById(id)?.remove())
    this.provisionalIds = []
    document.querySelectorAll('[id^="composer_"].hidden').forEach((el) => el.classList.remove("hidden"))
  }

  // ------------------------------------------------------------- private ---

  get templateId() {
    return this.element.dataset.composerTemplateId || "composer_template"
  }

  // Where a file-level comment lands. The review screen holds every Markdown
  // file in the pull request, so there is one threads container per file,
  // keyed by path (`data-file-threads-for`) rather than the single
  // `#file_threads` the seam started with — which is kept as the fallback for
  // a page that still renders one file on its own.
  fileThreadsContainer(form) {
    const path = form.querySelector('[data-composer-target="path"]')?.value
    const forPath = path && document.querySelector(`[data-file-threads-for="${CSS.escape(path)}"]`)
    return forPath || document.getElementById("file_threads")
  }

  // Which button sent it. A comment added to a review comes back as a PENDING
  // draft and the settled thread wears the pending band; a single comment does
  // not. Reading the submitter means the band is right from the first frame
  // rather than appearing or vanishing when the response lands.
  submittedIntoReview(event) {
    const submitter = event.detail?.formSubmission?.submitter
    const target = submitter?.dataset?.composerTarget
    return target === "reviewButton" || target === "replyReviewButton"
  }

  // The optimistic card is laid out as the settled thread, not as a smaller
  // preview of it (2026-09-26: "this transition from the saving state to the
  // final state causes a UI jump"). Every row the real thread has is here —
  // the tools in the card's top right, the reactions row, the reply box and
  // the resolve control beside it — so the space they will need is already
  // taken. They are disabled rather than omitted, and the three containers
  // that hold them are `inert`, which is what keeps a control that cannot
  // work yet out of the tab order and out of the accessibility tree.
  //
  // Whether the settled thread ends up with a Resolve button at all depends
  // on `viewerCanResolve`, which the client cannot know — it does not matter,
  // because that control shares the reply box's row (DESIGN.md §8) and so
  // changes the row's width, never its height.
  //
  // The `.reaction-picker` wrapper around the reaction trigger is not
  // decoration either. It is inline-block in the real card, which makes that
  // row five pixels taller than the 24px trigger it holds; without it the
  // provisional card was five pixels short and the jump came back smaller
  // rather than gone. `test/system/features/optimistic_comment_test.rb` is
  // what holds all of this to the pixel.
  buildProvisionalCard(body, intoReview) {
    const id = `comment_provisional_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`
    const login = this.element.dataset.composerViewerLogin || ""
    const avatar = this.element.dataset.composerViewerAvatar || ""

    const card = document.createElement("div")
    card.id = id
    card.className = `thread thread--sending${intoReview ? " thread--pending" : ""}`
    card.dataset.testid = "provisional-comment"
    card.innerHTML = `
      <div class="thread-comments">
        <div>
          <article class="comment-card">
            <div class="comment-head">
              ${avatar ? `<img alt="" class="avatar h-6 w-6" loading="lazy" src="${this.escapeHtml(avatar)}">` : ""}
              ${login ? `<span class="comment-author">${this.escapeHtml(login)}</span>` : ""}
              <time class="whitespace-nowrap">less than a minute ago</time>
              <span class="pill-pending">Sending…</span>
              <div class="comment-tools" inert>
                ${this.provisionalIcon(PENCIL_PATHS, "Edit")}
                ${this.provisionalIcon(BIN_PATHS, "Delete", "comment-icon--danger")}
                ${this.provisionalIcon(EXTERNAL_PATHS, "On GitHub")}
              </div>
            </div>
            <div class="comment-body md-prose md-prose-compact">
              <p>${this.escapeHtml(body).replace(/\n/g, "<br>")}</p>
            </div>
            <div class="comment-actions" inert>
              <span class="reaction-picker relative inline-block">
                <span class="reaction-add">${this.provisionalSvg(REACTION_PATHS)}</span>
              </span>
            </div>
          </article>
        </div>
      </div>
      <div class="thread-foot" inert>
        <div class="composer-card composer-card--compact">
          <textarea class="composer-textarea w-full" rows="1" placeholder="Reply…" disabled></textarea>
        </div>
        <div class="thread-foot-actions">
          <button type="button" class="btn btn-ghost btn-sm" disabled>Resolve</button>
        </div>
      </div>
    `
    return card
  }

  provisionalIcon(paths, name, extraClass = "") {
    return `<span class="comment-icon ${extraClass}">${this.provisionalSvg(paths)}<span class="sr-only">${name}</span></span>`
  }

  provisionalSvg(paths) {
    return `<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"
                 stroke-linecap="round" stroke-linejoin="round" class="h-4 w-4" aria-hidden="true">${paths}</svg>`
  }

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }

  fillFields(fragment, button) {
    const set = (targetName, value) => {
      const field = fragment.querySelector(`[data-composer-target="${targetName}"]`)
      if (field) field.value = value ?? ""
    }

    const commentable = button.dataset.commentable === "true"
    const anchor = this.parseAnchor(button.dataset.anchor)

    set("blockId", button.dataset.blockId)
    set("blockText", button.dataset.blockText)
    set("blockStartLine", button.dataset.startLine)
    set("blockEndLine", button.dataset.endLine)
    set("uncommentableReason", button.dataset.uncommentableReason || "")
    set("subjectType", commentable ? "line" : "file")
    set("pendingReviewNodeId", this.pendingReviewNodeId)
    set("pendingReviewId", this.pendingReviewId)
    set("pendingCount", this.pendingCount)

    if (commentable && anchor) {
      set("line", anchor.line)
      set("side", anchor.side)
      set("startLine", anchor.start_line)
      set("startSide", anchor.start_side)
    } else {
      set("line", "")
      set("side", "")
      set("startLine", "")
      set("startSide", "")
    }

    this.fillAnchorNote(fragment, commentable, anchor, button)

    // Every fresh clone starts from the <template>'s server-rendered label,
    // which reflects whatever the pending review was at page load — bring it
    // up to date with whatever pending-review:changed has told us since.
    const reviewButton = fragment.querySelector('[data-composer-target="reviewButton"]')
    if (reviewButton) reviewButton.textContent = this.pendingReviewNodeId ? "Add review comment" : "Start a review"
    this.applyReviewOnly(fragment)
  }

  parseAnchor(json) {
    if (!json || json === "null") return null
    try {
      return JSON.parse(json)
    } catch {
      return null
    }
  }

  // The composer says nothing about line numbers (W4): the reviewer picked
  // the block by clicking it, and the line is plumbing we still send to
  // GitHub. The note is left for the one thing worth saying — why a block
  // cannot be anchored at all — so in the ordinary case it stays empty and
  // hidden rather than narrating "Lines 3-4".
  fillAnchorNote(fragment, commentable, anchor, button) {
    const note = fragment.querySelector('[data-composer-target="anchorNote"]')
    const filePreviewNote = fragment.querySelector('[data-composer-target="filePreviewNote"]')

    if (commentable && anchor) {
      if (note) {
        note.textContent = ""
        note.hidden = true
      }
      if (filePreviewNote) filePreviewNote.hidden = true
    } else {
      const explanations = fragment.querySelector('[data-composer-target="explanations"]')
      const reason = button.dataset.uncommentableReason
      const key = reason ? reason.replace(/_/g, "-") : null
      const explanation = key && explanations ? explanations.dataset[this.camelize(key)] : null
      if (note) {
        note.textContent = explanation || "This block can't be anchored to a line."
        note.hidden = false
      }
      if (filePreviewNote) filePreviewNote.hidden = false
    }
  }

  camelize(dashed) {
    return dashed.replace(/-([a-z])/g, (_, c) => c.toUpperCase())
  }
}
