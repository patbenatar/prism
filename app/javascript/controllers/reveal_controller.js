import { Controller } from "@hotwired/stimulus"
import { revealHashTarget } from "controllers/reveal"

// Keeps the URL's promise: whatever `#…` points at is on screen, even when it
// is inside a collapsed file or a folded run of unchanged blocks, and even
// when it is a section link that names no id at all.
//
// Without this, following a link into hidden content fails silently and in the
// worst possible way — the browser scrolls somewhere plausible, nothing is
// wrong on screen, and the block the link named is simply not there. That
// covers every `#block_…` permalink, the file switcher's jump menu, the
// redirect the old per-file URL still performs, and every heading's link and
// in-document link (`#docs/guide.md:setup`, see `controllers/fragments`).
//
// It runs on connect for the URL the page arrived with, and on `hashchange`
// for every jump after that. The browser has already done its own scroll by
// the time either fires, so `revealHashTarget` repeats it once the content is
// actually visible — or does it for the first time, for a section link.
//
// Connect covers both ways of arriving: a full load, and a Turbo Drive visit,
// which renders a new <body> and so a new instance of this controller. Turbo
// looks the fragment up as an id, finds nothing for a section link and
// scrolls to the top; this then puts the reader where the link said.
export default class extends Controller {
  connect() {
    this.onHashChange = () => revealHashTarget()
    window.addEventListener("hashchange", this.onHashChange)

    // A frame late on purpose: `connect` can run before the browser has
    // finished its own fragment scroll, and scrolling twice in one frame
    // leaves the page wherever the second one started from.
    const restoring = arrivedBy === "restore"
    requestAnimationFrame(() => {
      // Back and forward into this page are Turbo restoration visits, and a
      // position Turbo puts back beats jumping to the fragment again: the
      // reader may have read on past it. But Turbo usually has nothing to put
      // back. Leaving for a shorter page clamps the scroll to the top while
      // the old entry is still current, and that top is what Turbo records
      // for it — so a restore that lands at 0 is Turbo's loss, not the
      // reader's choice, and the fragment is the better guess.
      if (restoring && window.scrollY > 0) return

      revealHashTarget()
    })
  }

  disconnect() {
    window.removeEventListener("hashchange", this.onHashChange)
  }

  // data-action="click->reveal#follow" on the page.
  //
  // A same-page link whose fragment is already the URL's changes nothing, so
  // no `hashchange` fires and the browser, finding no id by that name, does
  // not scroll either. Clicking "Setup" in the contents a second time, after
  // reading on, has to take you back there all the same. Everything else is
  // the link's own native navigation: a new history entry, a `hashchange`,
  // and the handler above.
  follow(event) {
    const link = event.target.closest?.('a[href^="#"]')
    if (!link || link.hash !== window.location.hash) return

    revealHashTarget()
  }
}

// How the page currently on screen arrived, from the Turbo visit that
// rendered it; null for a full page load. Module-level because the visit
// starts before the new <body>, and so before this controller exists.
let arrivedBy = null
document.addEventListener("turbo:visit", (event) => { arrivedBy = event.detail.action })

// ── Back and forward between two places on this page ─────────────────────
//
// Every section link, contents link and file-switcher row is a native
// fragment navigation, which pushes a history entry the way a reader expects:
// jump to "Setup", press Back, and you are at the contents again. Turbo then
// adopts each such entry (its `historyPoppedWithEmptyState`), so the entry
// carries Turbo's state — and Turbo 8 has no notion of a same-page history
// step. Popping back to an entry with its state is a restoration visit, which
// replaces the <body> with a cached copy of itself: the open composer is
// thrown away, every controller reconnects, all to move a scroll position the
// browser was about to move anyway.
//
// So a pop that stays on the document already on screen — same path, same
// query, only the fragment differs — does everything Turbo's own popstate
// handler does except start that visit. The wrap is on the delegate method
// Turbo's `History` calls once it has already recorded the new location,
// restoration identifier and index, so its next visit, its scroll bookkeeping
// and its sense of direction all stay exactly as Turbo would have left them.
// The `hashchange` the browser fires next does the scrolling.
//
// Wrapping rather than listening first: a popstate listener cannot get ahead
// of Turbo's, which is registered on `window` the moment Turbo is imported,
// and Chromium runs listeners at the window in the order they were added
// whatever their phase. The method is not public API; if a Turbo upgrade
// renames it, the guard below leaves Turbo alone and same-page Back simply
// costs a re-render again, which is how it behaved before.
let renderedPath = currentPath()
document.addEventListener("turbo:load", () => { renderedPath = currentPath() })

const session = window.Turbo?.session
const popped = session?.historyPoppedToLocationWithRestorationIdentifierAndDirection

if (typeof popped === "function") {
  session.historyPoppedToLocationWithRestorationIdentifierAndDirection = function (location, ...rest) {
    const samePage = location.pathname + location.search === renderedPath &&
      document.getElementById("file_view")
    if (samePage) return

    return popped.call(this, location, ...rest)
  }
}

function currentPath() {
  return window.location.pathname + window.location.search
}
