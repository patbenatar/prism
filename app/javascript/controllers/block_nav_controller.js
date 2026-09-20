import { Controller } from "@hotwired/stimulus"

// "n" and "p" jump to the next and previous changed block, the way a reviewer
// moves through a diff. The count in the file bar becomes "3 of 12 changed
// blocks" while you're moving, so the keys say where they put you.
//
// The Markdown tab holds every file in the pull request, and the walk crosses
// file boundaries without noticing them: blocks are collected in document
// order from the whole page, so "n" off the end of one file lands on the
// first change in the next. That is the point of the one-page screen — a
// reviewer walks the review, not a file.
//
// Focus follows the jump onto that block's "+", which means the next key after
// a jump can be Enter to comment, and a screen reader announces the block
// rather than leaving the caret at the top of the page.
export default class extends Controller {
  static targets = ["position"]

  connect() {
    this.index = -1
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
    const step = key === "n" ? 1 : -1
    this.index = this.wrap(this.nextIndex(blocks) + step, blocks.length)
    this.goTo(blocks[this.index], this.index, blocks.length)
  }

  // Start from whatever is on screen rather than from wherever the last jump
  // left off, so scrolling by hand and then pressing "n" does the obvious
  // thing.
  nextIndex(blocks) {
    if (this.index >= 0 && this.index < blocks.length) return this.index

    const top = blocks.findIndex((block) => block.getBoundingClientRect().bottom > 0)
    return top === -1 ? blocks.length : top - 1
  }

  wrap(index, length) {
    return ((index % length) + length) % length
  }

  goTo(block, index, total) {
    block.style.scrollMarginTop = `${this.stickyHeight(block) + 12}px`
    block.scrollIntoView({ behavior: "smooth", block: "start" })
    block.querySelector(".md-add")?.focus({ preventScroll: true })

    if (this.hasPositionTarget) {
      this.positionTarget.textContent = `${index + 1} of ${this.resting}`
    }
  }

  // Three bars are pinned above a block now, not two: the app's top bar, the
  // review bar, and the heading of the file the block is in. Measured rather
  // than assumed, because all three wrap at phone width.
  stickyHeight(block) {
    const section = block?.closest("[data-file-key]")
    const bars = [
      document.querySelector(".topbar"),
      this.element.querySelector(".filebar"),
      section?.querySelector('[data-testid="file-head"]')
    ]
    return bars.reduce((total, bar) => total + (bar?.offsetHeight ?? 0), 0)
  }

  isTyping(node) {
    if (!node) return false
    if (node.isContentEditable) return true
    return ["INPUT", "TEXTAREA", "SELECT"].includes(node.tagName)
  }
}
