import { Controller } from "@hotwired/stimulus"

// Asks before submitting a form: the trigger opens a <dialog> that carries
// the explanation and the real button.
//
// **The form works without this controller.** The trigger is an ordinary
// submit button inside the form, so with JavaScript off — or in the moment
// before Stimulus connects — clicking it posts the form the way it always
// did. That loses the confirmation, not the function, which is the right way
// round: a control that does nothing without JavaScript is worse than one
// that acts without asking first.
//
// `showModal()` does the hard parts, which is the whole reason for a native
// <dialog>: focus is trapped inside it, Escape closes it, the rest of the
// page goes inert, and the browser hands focus back to whatever had it when
// the dialog opened. What is left here is intercepting the click, treating a
// click on the backdrop as a cancel, making sure focus really does come back
// to the trigger, and not stranding an open dialog in the top layer when
// Turbo replaces this markup underneath it.
export default class extends Controller {
  static targets = ["dialog", "trigger", "confirm"]

  open(event) {
    // Nothing to open, or a browser without <dialog>: leave the click alone
    // and let it submit, exactly as it would with no JavaScript at all.
    if (!this.hasDialogTarget || typeof this.dialogTarget.showModal !== "function") return

    event.preventDefault()
    this.dialogTarget.showModal()

    // Land on the commit button rather than the first tabbable thing: it is
    // what the dialog is for, and Escape and Cancel are both one key away.
    if (this.hasConfirmTarget) this.confirmTarget.focus()
  }

  cancel() {
    this.dialogTarget.close()
  }

  // A click on the backdrop reports the dialog itself as its target — the
  // panel inside it catches everything else. The dialog carries no padding
  // of its own, so there is no rim of "inside" that behaves like outside.
  cancelOnBackdrop(event) {
    if (event.target === this.dialogTarget) this.dialogTarget.close()
  }

  // Belt and braces over the browser's own focus restoration, which does not
  // survive a trigger that has been re-rendered. Skipped once this markup is
  // gone: after a successful submit Turbo replaces the whole control, and
  // there is no trigger left to go back to.
  restoreFocus() {
    if (this.hasTriggerTarget && this.triggerTarget.isConnected) this.triggerTarget.focus()
  }

  disconnect() {
    if (this.hasDialogTarget && this.dialogTarget.open) this.dialogTarget.close()
  }
}
