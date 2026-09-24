import { Controller } from "@hotwired/stimulus"

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
  open(event) {
    const button = event.currentTarget
    const blockId = button.dataset.blockId
    if (!blockId) return

    const container = document.getElementById(`composer_${blockId}`)
    if (!container) return

    const alreadyOpenHere = container.childElementCount > 0

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

  // data-action="keydown->composer#keydown" on the composer's own textarea.
  keydown(event) {
    if (event.key === "Escape") {
      this.close(event)
      return
    }

    const submitting = (event.metaKey || event.ctrlKey) && event.key === "Enter"
    if (!submitting) return

    event.preventDefault()
    const form = event.target.closest("form")
    // While a review is open the single-comment button is gone, so Cmd+Enter
    // has to submit the review button instead — submitting the hidden one
    // would post exactly the comment the UI has stopped offering.
    const button =
      form?.querySelector('[data-composer-target="singleButton"]:not([hidden])') ||
      form?.querySelector('[data-composer-target="reviewButton"]')
    button ? form.requestSubmit(button) : form?.requestSubmit()
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

    const card = this.buildProvisionalCard(body)
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

  buildProvisionalCard(body) {
    const id = `comment_provisional_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`
    const login = this.element.dataset.composerViewerLogin || ""
    const avatar = this.element.dataset.composerViewerAvatar || ""

    const card = document.createElement("div")
    card.id = id
    card.className = "thread thread--pending"
    card.dataset.testid = "provisional-comment"
    card.innerHTML = `
      <article class="comment-card">
        <div class="comment-head">
          ${avatar ? `<img alt="" class="avatar h-6 w-6" loading="lazy" src="${this.escapeHtml(avatar)}">` : ""}
          ${login ? `<span class="comment-author">${this.escapeHtml(login)}</span>` : ""}
          <span class="pill-pending">Sending…</span>
        </div>
        <div class="comment-body md-prose md-prose-compact">${this.escapeHtml(body).replace(/\n/g, "<br>")}</div>
      </article>
    `
    return card
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
