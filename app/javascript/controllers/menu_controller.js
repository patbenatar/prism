import { Controller } from "@hotwired/stimulus"

// Closes a <details> menu when you click outside it or press Escape.
//
// The menu works without this controller — <details> opens and closes on its
// own summary — so this only adds the dismissal behaviour a pointer user
// expects. Attach to the <details> element itself.
export default class extends Controller {
  connect() {
    this.closeOnOutsideClick = this.closeOnOutsideClick.bind(this)
    this.closeOnEscape = this.closeOnEscape.bind(this)
    document.addEventListener("click", this.closeOnOutsideClick)
    document.addEventListener("keydown", this.closeOnEscape)
  }

  disconnect() {
    document.removeEventListener("click", this.closeOnOutsideClick)
    document.removeEventListener("keydown", this.closeOnEscape)
  }

  closeOnOutsideClick(event) {
    if (!this.element.open) return
    if (this.element.contains(event.target)) return
    this.element.open = false
  }

  closeOnEscape(event) {
    if (event.key !== "Escape" || !this.element.open) return
    this.element.open = false
    this.element.querySelector("summary")?.focus()
  }
}
