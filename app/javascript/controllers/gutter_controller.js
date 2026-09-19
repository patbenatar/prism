import { Controller } from "@hotwired/stimulus"

// Makes the review gutter easier to hit, and keeps a block visibly active
// while its composer is open.
//
// Showing and hiding the "+" is CSS (DESIGN §7) and needs no JavaScript. What
// CSS cannot do is give the affordance a target bigger than 24px: this
// forwards a click anywhere in a block's gutter column — the change bar, the
// empty space around it — to that block's own button. On a touch screen, where
// there is no hover, that turns the whole left margin into the comment
// affordance.
//
// Attach to the page root. Blocks are found by class, so blocks added later by
// a Turbo Stream work without re-connecting.
export default class extends Controller {
  static classes = ["active"]

  connect() {
    this.onClick = this.onClick.bind(this)
    this.element.addEventListener("click", this.onClick)

    // A composer opening or closing changes which block is the active one.
    // Only the mutated slots are inspected, not every block on the page — a
    // long document has hundreds, and a Turbo Stream write fires this.
    this.observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        const slot = mutation.target.closest?.(".md-composer")
        if (slot) this.markComposing(slot)
      }
    })
    this.observer.observe(this.element, { childList: true, subtree: true })
  }

  disconnect() {
    this.element.removeEventListener("click", this.onClick)
    this.observer?.disconnect()
  }

  onClick(event) {
    const gutter = event.target.closest(".md-gutter")
    if (!gutter || event.target.closest(".md-add")) return

    const button = gutter.querySelector(".md-add")
    if (!button) return

    event.preventDefault()
    button.click()
  }

  // A block whose composer slot has something in it stays lit, so you can see
  // which block you are writing about while the page scrolls under the form.
  markComposing(slot) {
    const block = slot.closest("[data-block-id]")
    if (block) block.toggleAttribute("data-composing", slot.childElementCount > 0)
  }
}
