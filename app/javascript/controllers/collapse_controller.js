import { Controller } from "@hotwired/stimulus"

// Keeps a <details>'s own word in sync with its state: "Show" when closed,
// "Hide" when open.
//
// The disclosure itself is native — a removed strip, the outdated section and
// a resolved thread all open and close with JavaScript off. This only writes
// the label, so the page never claims "Show" while the content is already on
// screen.
//
// Attach to the <details> and mark the word with
// `data-collapse-target="label"`.
export default class extends Controller {
  static targets = ["label"]
  static values = { shown: { type: String, default: "Hide" },
                    hidden: { type: String, default: "Show" } }

  connect() {
    this.update = this.update.bind(this)
    this.element.addEventListener("toggle", this.update)
    this.update()
  }

  disconnect() {
    this.element.removeEventListener("toggle", this.update)
  }

  update() {
    if (!this.hasLabelTarget) return
    this.labelTarget.textContent = this.element.open ? this.shownValue : this.hiddenValue
  }
}
