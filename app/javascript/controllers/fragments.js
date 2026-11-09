// What a `#…` in the address bar names on the Markdown tab.
//
// Most fragments on this page are real ids — a file's `#f-…`, a block's
// `#block_…` — and the browser finds those itself. A section link is not. Its
// fragment is the reader's form, `#docs/guide.md:overview`: the file's path, a
// colon, and the slug GitHub would give the heading (see Markdown::Anchors).
// The element it names has the namespaced id `user-content-<file key>-overview`,
// because every id in a repository's document is namespaced so it cannot
// collide with Prism's own, and scoped to its file because the page holds
// every Markdown file in the pull request. GitHub does the same mapping for
// the same reason: its address bar says `#overview` and its JavaScript finds
// `#user-content-overview`.
//
// Not a Stimulus controller; a plain module under controllers/ for the reason
// `controllers/reveal` gives.

const PREFIX = "user-content-"

// The element `hash` points at, or null. In order:
//
//   1. A real id. Prism's own fragments, and a namespaced id pasted whole.
//   2. `<path>:<name>` — matched against the paths of the files actually on
//      the page rather than split on the colon, because a path may contain
//      one and the longest file that matches is the one meant. A section that
//      no longer exists (renamed in a later push) lands on its file, which is
//      the most a stale link can still honestly promise.
//   3. GitHub's forms, `#overview` and `#user-content-overview`, which name no
//      file. The first file on the page that has that section wins, which is
//      exactly right for the common case — a page with one Markdown file — and
//      a reasonable guess for the rest.
export function fragmentTarget(hash = window.location.hash) {
  const name = decode(hash)
  if (!name) return null

  const direct = document.getElementById(name)
  if (direct) return direct

  const sections = fileSections()

  const file = fileNamed(sections, name)
  if (file) {
    const rest = name.slice(file.dataset.filePath.length + 1)
    return byName(file, rest) || file
  }

  const bare = name.startsWith(PREFIX) ? name.slice(PREFIX.length) : name
  for (const section of sections) {
    const element = byName(section, bare)
    if (element) return element
  }

  return null
}

// True when the browser could not have scrolled to `element` on its own,
// because the fragment it came from is not that element's id. The caller has
// to do the scroll itself.
export function needsOwnScroll(element, hash = window.location.hash) {
  return Boolean(element) && element.id !== decode(hash)
}

// `decodeURIComponent` because a path with a space in it, or a heading in any
// language but English, arrives percent-encoded; a malformed escape is taken
// as written rather than thrown.
function decode(hash) {
  if (!hash || hash === "#") return ""

  const raw = hash.startsWith("#") ? hash.slice(1) : hash
  try {
    return decodeURIComponent(raw)
  } catch {
    return raw
  }
}

function fileSections() {
  return Array.from(document.querySelectorAll('[data-testid="file-section"][data-file-key]'))
}

function fileNamed(sections, name) {
  let best = null
  for (const section of sections) {
    const path = section.dataset.filePath
    if (!path || !name.startsWith(`${path}:`)) continue
    if (!best || path.length > best.dataset.filePath.length) best = section
  }
  return best
}

// `getElementById` rather than a selector, so nothing a heading's slug
// contains has to be escaped; `contains` so a scoped id can only ever resolve
// inside the file it was scoped to.
function byName(section, name) {
  if (!name) return null

  const element = document.getElementById(`${PREFIX}${section.dataset.fileKey}-${name}`)
  return element && section.contains(element) ? element : null
}
