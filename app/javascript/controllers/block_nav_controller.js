import { Controller } from "@hotwired/stimulus"
import { reveal } from "controllers/reveal"

// "n" and "p" walk the blocks this pull request changed, the way a reviewer
// moves through a diff. The count in the file bar becomes "3 of 12 changed
// blocks" while you're moving, so the keys say where they put you.
//
// **They move relative to where you are, not through a remembered position.**
// "n" goes to the first change starting below the bottom of the pinned bars —
// which is the real top of the readable area — and "p" to the last one above
// it. Scroll by hand and press "n" and you go to the next change from there,
// every time; there is no stored index to fall out of step with the page. Both
// wrap: "n" off the last change returns to the first, because a pull request
// is a loop you go round rather than a list you fall off the end of, and the
// position counter says where you landed so the wrap is never a surprise.
//
// The walk crosses file boundaries without noticing them — blocks are
// collected in document order from the whole page, so "n" off the end of one
// file lands on the first change in the next. That is the point of the
// one-page screen: a reviewer walks the review, not a file.
//
// It also crosses *collapsed* boundaries. A change inside a collapsed file is
// still a change, so the jump opens the file on the way in. A folded run of
// unchanged blocks can never contain one, so it is never in the way.
//
// Focus follows the jump onto that block's "+", which means the next key after
// a jump can be Enter to comment, and a screen reader announces the block
// rather than leaving the caret at the top of the page.
export default class extends Controller {
  static targets = ["position"]

  // How long after a jump the destination still counts as "where I am".
  //
  // `scrollIntoView` is smooth, so for a few hundred milliseconds the viewport
  // is somewhere between the old position and the new one. Pressing "n" twice
  // quickly must step twice, not measure the middle of the first scroll — so
  // within this window the walk steps from the block it last sent you to
  // rather than from the viewport.
  static SETTLING_MS = 700

  connect() {
    this.landed = null
    this.landedAt = 0
    this.resting = this.hasPositionTarget ? this.positionTarget.textContent.trim() : ""
    this.onKeydown = this.onKeydown.bind(this)
    document.addEventListener("keydown", this.onKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
  }

  get blocks() {
    return Array.from(
      this.element.querySelectorAll('.md-block[data-change]:not([data-change="unchanged"])')
    )
  }

  onKeydown(event) {
    if (event.metaKey || event.ctrlKey || event.altKey) return
    if (this.isTyping(event.target)) return

    const key = event.key.toLowerCase()
    if (key !== "n" && key !== "p") return

    const blocks = this.blocks
    if (blocks.length === 0) return

    event.preventDefault()
    const index = key === "n" ? this.nextIndex(blocks) : this.previousIndex(blocks)
    this.goTo(blocks[index], index)
  }

  // The first change that starts below the readable area's top edge, or back
  // to the first change on the page when there is none left.
  nextIndex(blocks) {
    const settling = this.settlingIndex(blocks)
    if (settling !== null) return this.wrap(settling + 1, blocks.length)

    const line = this.restLine()
    const found = blocks.findIndex((block) => this.topOf(block) > line)
    return found === -1 ? 0 : found
  }

  // The last change that starts above it, or round to the last change on the
  // page.
  previousIndex(blocks) {
    const settling = this.settlingIndex(blocks)
    if (settling !== null) return this.wrap(settling - 1, blocks.length)

    const line = this.restLine()
    for (let index = blocks.length - 1; index >= 0; index--) {
      if (this.topOf(blocks[index]) < line) return index
    }
    return blocks.length - 1
  }

  // Where a jump comes to rest: just under the pinned bars, which is also the
  // line either key measures against. A block sitting exactly there is the one
  // you are on, so it is neither "below" nor "above" and both keys step past
  // it. The tolerance absorbs sub-pixel scroll positions.
  restLine() {
    return this.stickyHeight() + 12 + 4
  }

  // A block inside a collapsed file has no box of its own — every measurement
  // on it comes back zero, which would read as "at the very top of the
  // viewport" and put every change in a collapsed file permanently behind
  // you. It stands where its file's heading stands instead, which is exactly
  // where the reviewer would find it if they opened the file.
  topOf(block) {
    if (block.offsetParent !== null) return block.getBoundingClientRect().top

    const section = block.closest('[data-testid="file-section"]')
    return section ? section.getBoundingClientRect().top : 0
  }

  // Mid-scroll, "where I am" is where the scroll is taking me. Returns null
  // once it has settled, or if the destination has left the page.
  settlingIndex(blocks) {
    if (!this.landed || !this.landed.isConnected) return null
    if (Date.now() - this.landedAt > this.constructor.SETTLING_MS) return null

    const index = blocks.indexOf(this.landed)
    return index === -1 ? null : index
  }

  wrap(index, length) {
    return ((index % length) + length) % length
  }

  goTo(block, index) {
    // A change can be inside a file the reviewer collapsed. Open it first:
    // scrolling to a `hidden` element does nothing at all, silently.
    reveal(block)

    this.landed = block
    this.landedAt = Date.now()

    block.style.scrollMarginTop = `${this.stickyHeight(block) + 12}px`
    block.scrollIntoView({ behavior: "smooth", block: "start" })
    block.querySelector(".md-add")?.focus({ preventScroll: true })

    if (this.hasPositionTarget) {
      this.positionTarget.textContent = `${index + 1} of ${this.resting}`
    }
  }

  // Three bars are pinned above a block, not two: the app's top bar, the
  // review bar, and the heading of the file the block is in. Measured rather
  // than assumed, because all three wrap at phone width.
  //
  // Without a block — when all this needs is the line the two keys measure
  // against — any file's heading will do: they are the same bar rendered once
  // per file, so they are the same height.
  stickyHeight(block = null) {
    const section = block?.closest("[data-file-key]")
    const bars = [
      document.querySelector(".topbar"),
      this.element.querySelector(".filebar"),
      section?.querySelector('[data-testid="file-head"]') ||
        this.element.querySelector('[data-testid="file-head"]')
    ]
    return bars.reduce((total, bar) => total + (bar?.offsetHeight ?? 0), 0)
  }

  isTyping(node) {
    if (!node) return false
    if (node.isContentEditable) return true
    return ["INPUT", "TEXTAREA", "SELECT"].includes(node.tagName)
  }
}
