import { Controller } from "@hotwired/stimulus"

// The Markdown tab's file navigation: which file you are reading, and how far
// under the pinned bars anything scrolled to has to land.
//
// The jump menu itself needs none of this. Its rows are plain `#fragment`
// links and the browser's own anchor scrolling does the work, so switching
// files works with JavaScript off. This adds the two things the browser
// cannot do on its own:
//
//   1. **Publishes the file bar's measured height as `--filebar-height`.**
//      Each file's heading sticks under that bar, and the bar's height is not
//      a constant — it wraps at phone width. Measuring it beats picking a
//      number that is wrong at one of the two widths (the same lesson as
//      `--tray-height`, DESIGN.md §8).
//   2. **Says which file you are in**, in the switcher's summary and as
//      `aria-current` on its rows, so the menu is a position as well as a
//      destination.
export default class extends Controller {
  static targets = ["bar", "label", "position", "item"]

  connect() {
    // The file sections, not everything carrying a file key: the jump menu's
    // own rows carry one too, and counting those made the summary say
    // "guide.md 3/4" for the third of four *menu rows*.
    this.sections = Array.from(this.element.querySelectorAll('[data-testid="file-section"]'))

    this.measure = this.measure.bind(this)
    this.measure()
    this.resizeObserver = new ResizeObserver(this.measure)
    if (this.hasBarTarget) this.resizeObserver.observe(this.barTarget)
    window.addEventListener("resize", this.measure)

    this.watchSections()
  }

  disconnect() {
    this.resizeObserver?.disconnect()
    this.intersectionObserver?.disconnect()
    window.removeEventListener("resize", this.measure)
    document.documentElement.style.removeProperty("--filebar-height")
  }

  // data-action="file-nav#jump" on every row of the menu.
  //
  // The navigation is the anchor's own — this closes the menu behind it,
  // which a <details> does not do by itself, and names the file you just
  // chose straight away. That last part is not cosmetic: two short files can
  // both fit on one screen, so a jump to the second may not scroll far enough
  // to move the "which file am I in" line, and the menu would go on claiming
  // you were in the first. The scroll spy takes over again once you scroll.
  jump(event) {
    this.element.querySelectorAll("details[open]").forEach((menu) => {
      if (menu.contains(event.currentTarget)) menu.open = false
    })

    const key = event.currentTarget.dataset.fileKey
    if (!key) return

    this.jumpedAt = Date.now()
    this.show(key)
  }

  measure() {
    if (!this.hasBarTarget) return

    const height = Math.round(this.barTarget.getBoundingClientRect().height)
    if (height > 0) document.documentElement.style.setProperty("--filebar-height", `${height}px`)
  }

  // The file being read is the last one whose heading has passed under the
  // pinned bars — which is what a sticky heading already shows, so the
  // switcher agrees with the page rather than with the viewport's midpoint.
  watchSections() {
    if (this.sections.length === 0) return

    this.intersectionObserver = new IntersectionObserver(() => this.markCurrent(), {
      rootMargin: "-25% 0px -60% 0px",
      threshold: 0
    })
    this.sections.forEach((section) => this.intersectionObserver.observe(section))
    this.markCurrent()
  }

  markCurrent() {
    // An anchor jump makes the observer fire immediately; let the file the
    // reviewer just picked stand rather than being corrected by the scroll it
    // caused.
    if (this.jumpedAt && Date.now() - this.jumpedAt < 750) return

    const top = this.stickyHeight() + 4
    let current = this.sections[0]

    for (const section of this.sections) {
      if (section.getBoundingClientRect().top <= top) current = section
    }
    if (current) this.show(current.dataset.fileKey)
  }

  show(key) {
    const index = this.sections.findIndex((section) => section.dataset.fileKey === key)
    if (index === -1) return

    this.itemTargets.forEach((item) => {
      item.setAttribute("aria-current", String(item.dataset.fileKey === key))
    })

    if (this.hasLabelTarget) {
      this.labelTarget.textContent = this.basename(this.sections[index].dataset.filePath)
    }
    if (this.hasPositionTarget) {
      this.positionTarget.textContent = `${index + 1}/${this.sections.length}`
    }
  }

  stickyHeight() {
    const bars = [document.querySelector(".topbar"), this.hasBarTarget ? this.barTarget : null]
    return bars.reduce((total, bar) => total + (bar?.offsetHeight ?? 0), 0)
  }

  basename(path) {
    return String(path || "").split("/").pop()
  }
}
