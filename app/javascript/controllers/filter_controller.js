import { Controller } from "@hotwired/stimulus"

// Filters an already-rendered list as you type.
//
// The repository list arrives as one page of 100 repos sorted by most recent
// push, which is small enough to filter in the browser — no round trip, no
// spinner, and it keeps working while GitHub is rate-limiting us. Each item
// carries the text to match in `data-filter-text`.
//
//   <div data-controller="filter">
//     <input data-filter-target="query" data-action="input->filter#apply">
//     <div data-filter-target="item" data-filter-text="rails/rails a web framework">…</div>
//     <p data-filter-target="empty" hidden>…</p>
//     <span data-filter-target="count"></span>
//   </div>
export default class extends Controller {
  static targets = ["query", "item", "empty", "count", "hideWhenFiltering"]

  connect() {
    this.apply()
  }

  apply() {
    const term = (this.hasQueryTarget ? this.queryTarget.value : "").trim().toLowerCase()
    let matches = 0

    this.itemTargets.forEach((item) => {
      const hit = term === "" || (item.dataset.filterText || "").toLowerCase().includes(term)
      item.hidden = !hit
      if (hit) matches += 1
    })

    if (this.hasEmptyTarget) this.emptyTarget.hidden = matches !== 0 || term === ""
    if (this.hasCountTarget) this.countTarget.textContent = matches

    // "Load more" and other whole-list chrome make no sense mid-filter.
    this.hideWhenFilteringTargets.forEach((element) => { element.hidden = term !== "" })
  }

  // Escape clears the box and restores the full list.
  clear(event) {
    if (event && event.key !== "Escape") return
    if (this.hasQueryTarget) this.queryTarget.value = ""
    this.apply()
  }
}
