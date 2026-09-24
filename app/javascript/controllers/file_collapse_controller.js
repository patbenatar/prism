import { Controller } from "@hotwired/stimulus"

// Folds a whole file down to its heading, so a pull request with a dozen
// Markdown files reads as an index you open one file at a time.
//
// Expanded by default: the screen exists to show the documents, and a page
// that starts closed would make the reviewer click before reading anything.
//
// The body is `hidden`, never removed. Every id inside it still resolves,
// which is what lets an anchor, the file switcher's jump and an `n`/`p` walk
// land on a block inside a collapsed file and simply open it on the way —
// see `controllers/reveal`, which writes the same three things this does:
//
//   * `data-collapsed` on the <section>, which is the state of record
//   * `hidden` on the body target
//   * `aria-expanded` on the toggle
//
// That trio is the contract between the two. It is written in both places
// because `reveal` has to work from a hashchange with no controller instance
// in hand, and three attribute writes are cheaper than a lookup through
// Stimulus's registry.
//
// Collapsing does not touch the sticky heading, which keeps its path, status
// pill and diffstat — that is the whole point of collapsing.
export default class extends Controller {
  static targets = ["body", "toggle"]

  connect() {
    // Whatever the markup says, not whatever this instance last thought: a
    // Turbo restore can reconnect a controller onto a section that `reveal`
    // has already opened.
    this.sync(this.element.dataset.collapsed !== "true")
  }

  // data-action="file-collapse#toggle" on the chevron in the file heading.
  toggle(event) {
    event?.preventDefault()
    this.sync(this.element.dataset.collapsed === "true")
  }

  sync(expanded) {
    this.element.dataset.collapsed = String(!expanded)
    if (this.hasBodyTarget) this.bodyTarget.hidden = !expanded
    if (this.hasToggleTarget) this.toggleTarget.setAttribute("aria-expanded", String(expanded))
  }
}
