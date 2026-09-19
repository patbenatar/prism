import { Controller } from "@hotwired/stimulus"

// Toggles a comment between its rendered view and its edit form. Both panes
// are rendered up front (`review_comments/_comment`), so opening the editor
// costs no round trip; saving (or a validation error) replaces the whole
// `comment_<node_id>` container from the server, which resets this back to
// the view pane.
export default class extends Controller {
  static targets = ["viewPane", "editPane"]

  edit() {
    this.viewPaneTarget.hidden = true
    this.editPaneTarget.hidden = false

    const textarea = this.editPaneTarget.querySelector("textarea")
    if (!textarea) return
    textarea.focus()
    textarea.setSelectionRange(textarea.value.length, textarea.value.length)
  }

  cancelEdit() {
    this.editPaneTarget.hidden = true
    this.viewPaneTarget.hidden = false
  }
}
