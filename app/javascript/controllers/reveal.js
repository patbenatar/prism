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

// Opens every collapsed ancestor of `element`, innermost first. Returns true
// when something was actually opened, so a caller can wait a frame for layout
// before measuring or scrolling.
export function reveal(element) {
  if (!element) return false

  let opened = false

  for (const ancestor of ancestors(element)) {
    if (ancestor.matches("details.md-run") && !ancestor.open) {
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

// The element the current URL points at, if any. `decodeURIComponent` because
// a file key is plain hex but a future anchor may not be, and `getElementById`
// takes the raw id rather than a selector — so nothing here has to be escaped
// the way `querySelector` would need.
export function hashTarget(hash = window.location.hash) {
  if (!hash || hash === "#") return null

  try {
    return document.getElementById(decodeURIComponent(hash.slice(1)))
  } catch {
    return document.getElementById(hash.slice(1))
  }
}

// Reveals whatever the URL points at and scrolls to it. The browser has
// already done its own scroll by the time we get here and it landed on hidden
// content, so this repeats it now that the content is visible.
export function revealHashTarget(hash = window.location.hash) {
  const target = hashTarget(hash)
  if (!target) return false

  const opened = reveal(target)
  if (opened) target.scrollIntoView({ block: "start" })
  return opened
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

function* ancestors(element) {
  let node = element instanceof Element ? element : element?.parentElement
  while (node) {
    yield node
    node = node.parentElement
  }
}
