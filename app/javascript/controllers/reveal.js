// Make sure an element is actually on screen before anything tries to scroll
// to it.
//
// The Markdown tab hides content in two ways, and both are ordinary DOM
// rather than anything removed from the page: a whole file collapses to its
// heading (`file_collapse_controller`), and a run of blocks the pull request
// did not touch folds into a `<details class="md-run">`. Ids resolve either
// way, which is the point — an anchor, a jump from the file switcher and an
// `n`/`p` walk can all land on hidden content, and the fix is to open what is
// around it rather than to render anything again.
//
// Not a Stimulus controller, and deliberately here rather than in a `lib/`
// directory of its own: `pin_all_from "app/javascript/controllers"` already
// covers this file, and `eagerLoadControllersFrom` only registers paths ending
// in `_controller`, so a plain module alongside them is free. Import it as
// `controllers/reveal`.

import { fragmentTarget, needsOwnScroll } from "controllers/fragments"

// Opens every collapsed ancestor of `element`, innermost first. Returns true
// when something was actually opened, so a caller can wait a frame for layout
// before measuring or scrolling.
//
// Any closed <details>, not only a folded run: a section link can point into
// the strip of content the pull request removed, and an author can put a
// heading inside a `<details>` of their own. A link that names something
// should show it, whoever folded it.
export function reveal(element) {
  if (!element) return false

  let opened = false

  for (const ancestor of ancestors(element)) {
    if (ancestor.matches("details") && !ancestor.open && !isOwnSummary(ancestor, element)) {
      ancestor.open = true
      opened = true
    }

    if (ancestor.matches('[data-testid="file-section"]') && ancestor.dataset.collapsed === "true") {
      openFile(ancestor)
      opened = true
    }
  }

  return opened
}

// The element the current URL points at, if any. A section link's fragment
// is not an id, so this goes through `controllers/fragments` rather than
// straight to `getElementById`; that module also covers every fragment that
// is one.
export function hashTarget(hash = window.location.hash) {
  return fragmentTarget(hash)
}

// Reveals whatever the URL points at and scrolls to it, and reports whether
// it found anything.
//
// Two reasons to scroll, and either is enough. The target was hidden, so the
// browser's own scroll landed on nothing; or the fragment is a section link,
// which names no id, so the browser never scrolled at all. When the fragment
// is a real id and nothing had to open, the browser's scroll was right and is
// left alone.
//
// Either way the offset is CSS's: `scroll-margin-top` on the target clears
// the pinned bars, the same rule the browser's own fragment scroll obeys, so
// the two paths land in the same place.
export function revealHashTarget(hash = window.location.hash) {
  const target = hashTarget(hash)
  if (!target) return false

  const opened = reveal(target)
  if (opened || needsOwnScroll(target, hash)) {
    target.scrollIntoView({ block: "start" })
    holdInPlace(target)
  }
  return true
}

// Keeps a just-scrolled-to target under the bars while the page above it is
// still finding its height.
//
// An image above the heading has no height until it loads, and a mermaid
// diagram is drawn after the page arrives, so a jump that was exact when it
// happened can end up a screen short a second later — the heading the link
// named pushed off the bottom by a picture. The browser's own fragment
// scrolling has the same flaw; GitHub's too. This re-aligns on every change in
// the page's height for a few seconds, and lets go the moment the reader
// touches the page, because once they have scrolled the position is theirs.
const HOLD_MS = 3000
const LET_GO = ["wheel", "touchstart", "keydown", "mousedown"]
let releaseHold = null

function holdInPlace(target) {
  releaseHold?.()

  const page = target.closest("#file_view") || document.body
  const observer = new ResizeObserver(() => target.scrollIntoView({ block: "start" }))
  const timer = setTimeout(() => release(), HOLD_MS)

  function release() {
    observer.disconnect()
    clearTimeout(timer)
    LET_GO.forEach((type) => window.removeEventListener(type, release, true))
    if (releaseHold === release) releaseHold = null
  }

  LET_GO.forEach((type) => window.addEventListener(type, release, { capture: true, passive: true }))
  observer.observe(page)
  releaseHold = release
}

// `file_collapse_controller` owns this state; this writes it directly rather
// than reaching for the controller instance, because the same three lines have
// to work from `block_nav` and from a hashchange with no controller in hand.
// The attributes ARE the contract — see the controller's comment.
function openFile(section) {
  section.dataset.collapsed = "false"

  const body = section.querySelector('[data-file-collapse-target="body"]')
  if (body) body.hidden = false

  const toggle = section.querySelector('[data-file-collapse-target="toggle"]')
  if (toggle) toggle.setAttribute("aria-expanded", "true")
}

// A link to a <details>'s own summary is a link to something already on
// screen; opening the disclosure as well would be a side effect nobody asked
// for.
function isOwnSummary(details, element) {
  const summary = details.querySelector(":scope > summary")
  return Boolean(summary) && summary.contains(element)
}

function* ancestors(element) {
  let node = element instanceof Element ? element : element?.parentElement
  while (node) {
    yield node
    node = node.parentElement
  }
}
