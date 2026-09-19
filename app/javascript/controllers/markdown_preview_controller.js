import { Controller } from "@hotwired/stimulus"

// The Write/Preview tab pair inside the composer, the reply box and the edit
// form. Fetches GitHub's own rendering (MarkdownPreviewsController, which
// wraps Github::Client#render_markdown) the first time Preview is opened and
// again after the text changes, debounced so typing doesn't fire a request
// per keystroke.
export default class extends Controller {
  static targets = ["writeTab", "previewTab", "writePane", "previewPane", "previewBody", "textarea"]
  static values = { url: String }

  connect() {
    this.lastRenderedText = null
    this.debounceTimer = null
  }

  // data-action="input->markdown-preview#dirty" on the textarea. Cheap: just
  // invalidates the cache so the next tab-open re-fetches.
  dirty() {
    this.lastRenderedText = null
  }

  showWrite(event) {
    event?.preventDefault?.()
    this.writePaneTarget.hidden = false
    this.previewPaneTarget.hidden = true
    this.writeTabTarget.classList.add("tab-active")
    this.previewTabTarget.classList.remove("tab-active")
  }

  showPreview(event) {
    event?.preventDefault?.()
    this.writePaneTarget.hidden = true
    this.previewPaneTarget.hidden = false
    this.previewTabTarget.classList.add("tab-active")
    this.writeTabTarget.classList.remove("tab-active")
    this.schedule()
  }

  schedule() {
    const text = this.textareaTarget.value
    if (text === this.lastRenderedText) return

    if (!text.trim()) {
      this.previewBodyTarget.textContent = "Nothing to preview yet."
      this.lastRenderedText = text
      return
    }

    clearTimeout(this.debounceTimer)
    this.debounceTimer = setTimeout(() => this.fetchPreview(text), 250)
  }

  async fetchPreview(text) {
    if (!this.hasUrlValue || !this.urlValue) return

    const token = document.querySelector('meta[name="csrf-token"]')?.content

    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "X-CSRF-Token": token || "",
          Accept: "text/html"
        },
        body: new URLSearchParams({ text })
      })
      this.previewBodyTarget.innerHTML = await response.text()
      this.lastRenderedText = text
    } catch {
      this.previewBodyTarget.textContent = "Couldn't load the preview."
    }
  }
}
