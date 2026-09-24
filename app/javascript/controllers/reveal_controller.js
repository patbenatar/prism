import { Controller } from "@hotwired/stimulus"
import { revealHashTarget } from "controllers/reveal"

// Keeps the URL's promise: whatever `#…` points at is on screen, even when it
// is inside a collapsed file or a folded run of unchanged blocks.
//
// Without this, following a link into hidden content fails silently and in the
// worst possible way — the browser scrolls somewhere plausible, nothing is
// wrong on screen, and the block the link named is simply not there. That
// covers every `#block_…` permalink, the file switcher's jump menu, and the
// redirect the old per-file URL still performs.
//
// It runs on connect for the URL the page arrived with, and on `hashchange`
// for every jump after that. The browser has already done its own scroll by
// the time either fires, so `revealHashTarget` repeats it once the content is
// actually visible.
export default class extends Controller {
  connect() {
    this.onHashChange = () => revealHashTarget()
    window.addEventListener("hashchange", this.onHashChange)

    // A frame late on purpose: `connect` can run before the browser has
    // finished its own fragment scroll, and scrolling twice in one frame
    // leaves the page wherever the second one started from.
    requestAnimationFrame(() => revealHashTarget())
  }

  disconnect() {
    window.removeEventListener("hashchange", this.onHashChange)
  }
}
