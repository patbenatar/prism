import { Controller } from "@hotwired/stimulus"

// The sticky pending-review tray (`reviews/_pending_tray`, id="pending_tray").
//
// PLAN.md's seam puts `data-controller="composer pending-review"` on the file
// view's <main>, but the tray itself renders outside <main> (it goes through
// `content_for :tray`, yielded after `</main>` in the layout) — not a
// descendant, so a controller instance can't reach it through Stimulus
// targets. This partial also declares `pending-review` on its own root,
// which is the instance that actually does the work; every time Turbo
// replaces the tray, `connect()` re-fires and broadcasts the new state on
// `window` so composer_controller (which *does* persist across the replace)
// can update any open composer's review-button label without a reload.
// Value names deliberately don't repeat "pendingReview": Stimulus derives the
// attribute as `data-<identifier>-<valueName>-value`, and this controller's
// own identifier already *is* "pending-review" — naming a value
// `pendingReviewNodeId` would need `data-pending-review-pending-review-node-id-value`
// (the identifier twice), not the single `data-pending-review-node-id-value`
// the partial actually renders.
export default class extends Controller {
  static values = { nodeId: String, id: String, count: Number }

  connect() {
    window.dispatchEvent(
      new CustomEvent("pending-review:changed", {
        detail: {
          pendingReviewNodeId: this.nodeIdValue || null,
          pendingReviewId: this.idValue || null,
          pendingCount: this.countValue || 0
        }
      })
    )
  }
}
