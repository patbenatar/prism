import { Controller } from "@hotwired/stimulus"

// Opens/closes the comment composer under a block's gutter "+", per
// PLAN.md "Phase 2 seam: file view (D) <-> commenting (E)".
//
// Lives on the file view's <main> (data-controller="composer …"), which D
// renders with plain data attributes (not Stimulus `-value` attributes) —
// see the seam's `data-composer-template-id`, `-pending-review-node-id`,
// etc. Read directly off `this.element.dataset` rather than `static values`
// so this controller does not depend on D switching those to the Stimulus
// value convention.
//
// The gutter button itself (also D's) carries plain data attributes too, so
// D never needs this controller's JS loaded to render a valid page —
// `data-block-id`, `data-block-text`, `data-start-line`, `data-end-line`,
// `data-commentable`, `data-uncommentable-reason`, `data-anchor` (the
// Review::Anchor#to_rest JSON, or "null").
export default class extends Controller {
  connect() {
    this.openBlockId = null
    // Seeded from the seam's own data attribute (the server's knowledge at
    // page load); pending-review:changed keeps it current after that.
    this.pendingReviewNodeId = this.element.dataset.composerPendingReviewNodeId || null
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
    const button = form?.querySelector('[data-composer-target="singleButton"]')
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
  // review"/"Add review comment" label stays correct without a reload.
  syncPendingReview(event) {
    this.pendingReviewNodeId = event.detail?.pendingReviewNodeId || null

    this.element.querySelectorAll('[data-composer-target="reviewButton"]').forEach((button) => {
      button.textContent = this.pendingReviewNodeId ? "Add review comment" : "Start a review"
    })
  }

  // ------------------------------------------------------------- private ---

  get templateId() {
    return this.element.dataset.composerTemplateId || "composer_template"
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
  }

  parseAnchor(json) {
    if (!json || json === "null") return null
    try {
      return JSON.parse(json)
    } catch {
      return null
    }
  }

  fillAnchorNote(fragment, commentable, anchor, button) {
    const note = fragment.querySelector('[data-composer-target="anchorNote"]')
    const filePreviewNote = fragment.querySelector('[data-composer-target="filePreviewNote"]')

    if (commentable && anchor) {
      const range =
        anchor.start_line && anchor.start_line !== anchor.line
          ? `Lines ${anchor.start_line}–${anchor.line}`
          : `Line ${anchor.line}`
      if (note) note.textContent = range
      if (filePreviewNote) filePreviewNote.hidden = true
    } else {
      const explanations = fragment.querySelector('[data-composer-target="explanations"]')
      const reason = button.dataset.uncommentableReason
      const key = reason ? reason.replace(/_/g, "-") : null
      const explanation = key && explanations ? explanations.dataset[this.camelize(key)] : null
      if (note) note.textContent = explanation || "This block can't be anchored to a line."
      if (filePreviewNote) filePreviewNote.hidden = false
    }
  }

  camelize(dashed) {
    return dashed.replace(/-([a-z])/g, (_, c) => c.toUpperCase())
  }
}
