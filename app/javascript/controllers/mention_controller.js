import { Controller } from "@hotwired/stimulus"

// @-mention autocomplete for a composer/reply/edit textarea. Fetches the
// repository's mentionables once per page load (cached across every
// instance, since a file view can have many composers) and filters
// client-side from then on — GitHub does not validate mentions on write, so
// this is a convenience, not a correctness surface.
//
// Keyboard: ArrowUp/ArrowDown move the highlighted option, Enter/Tab accept
// it, Escape closes the list without inserting anything.
const cache = new Map()

export default class extends Controller {
  static targets = ["textarea", "list"]
  static values = { mentionablesUrl: String }

  connect() {
    this.people = []
    this.matches = []
    this.activeIndex = -1
    this.open = false
  }

  // data-action="input->mention#input"
  async input() {
    const match = this.currentMention()
    if (!match) return this.close()

    if (this.people.length === 0) this.people = await this.fetchPeople()
    const query = match.query.toLowerCase()

    this.matches = this.people
      .filter((p) => p.login.toLowerCase().includes(query) || (p.name || "").toLowerCase().includes(query))
      .slice(0, 8)

    this.matches.length ? this.show() : this.close()
  }

  // data-action="keydown->mention#keydown" — registered *before*
  // composer#keydown on the same textarea (see _composer_form), and calls
  // stopImmediatePropagation once it acts, so Escape closes the mention list
  // instead of also closing the whole composer and losing the draft.
  keydown(event) {
    if (!this.open) return

    if (event.key === "ArrowDown") {
      event.preventDefault()
      event.stopImmediatePropagation()
      this.move(1)
    } else if (event.key === "ArrowUp") {
      event.preventDefault()
      event.stopImmediatePropagation()
      this.move(-1)
    } else if (event.key === "Enter" || event.key === "Tab") {
      if (this.activeIndex >= 0) {
        event.preventDefault()
        event.stopImmediatePropagation()
        this.select(this.matches[this.activeIndex])
      }
    } else if (event.key === "Escape") {
      event.stopImmediatePropagation()
      this.close()
    }
  }

  move(delta) {
    this.activeIndex = (this.activeIndex + delta + this.matches.length) % this.matches.length
    this.render()
  }

  select(person) {
    const textarea = this.textareaTarget
    const match = this.currentMention()
    if (!match || !person) return

    const before = textarea.value.slice(0, match.start)
    const after = textarea.value.slice(textarea.selectionStart)
    const insertion = `@${person.login} `

    textarea.value = `${before}${insertion}${after}`
    const cursor = before.length + insertion.length
    textarea.setSelectionRange(cursor, cursor)
    textarea.focus()
    textarea.dispatchEvent(new Event("input", { bubbles: true }))

    this.close()
  }

  show() {
    this.open = true
    this.activeIndex = 0
    this.render()
  }

  close() {
    this.open = false
    this.activeIndex = -1
    this.listTarget.hidden = true
    this.listTarget.innerHTML = ""
    this.textareaTarget.removeAttribute("aria-activedescendant")
  }

  render() {
    this.listTarget.hidden = false
    this.listTarget.innerHTML = ""

    this.matches.forEach((person, index) => {
      const option = document.createElement("div")
      option.id = `mention_option_${index}`
      option.setAttribute("role", "option")
      option.setAttribute("aria-selected", index === this.activeIndex ? "true" : "false")
      option.className = `cursor-pointer px-3 py-1.5 ${
        index === this.activeIndex ? "bg-brand-soft text-brand" : "text-ink hover:bg-sunk"
      }`
      option.textContent = person.name ? `${person.login} – ${person.name}` : person.login
      option.addEventListener("mousedown", (event) => {
        event.preventDefault()
        this.select(person)
      })
      this.listTarget.appendChild(option)
    })

    if (this.activeIndex >= 0) {
      this.textareaTarget.setAttribute("aria-activedescendant", `mention_option_${this.activeIndex}`)
    }
  }

  // The "@word" run immediately before the caret, or null when the caret
  // isn't inside one.
  currentMention() {
    const textarea = this.textareaTarget
    const caret = textarea.selectionStart
    const upToCaret = textarea.value.slice(0, caret)
    const match = upToCaret.match(/@([\w-]*)$/)
    if (!match) return null

    return { start: caret - match[0].length, query: match[1] }
  }

  async fetchPeople() {
    if (!this.hasMentionablesUrlValue) return []

    if (!cache.has(this.mentionablesUrlValue)) {
      cache.set(
        this.mentionablesUrlValue,
        fetch(this.mentionablesUrlValue, { headers: { Accept: "application/json" } })
          .then((response) => (response.ok ? response.json() : []))
          .catch(() => [])
      )
    }

    return cache.get(this.mentionablesUrlValue)
  }
}
