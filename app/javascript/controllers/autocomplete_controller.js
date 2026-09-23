import { Controller } from "@hotwired/stimulus"

// Autocomplete inside a comment textarea, on two triggers:
//
//   @  people who can be mentioned here   → MentionablesController
//   #  issues and pull requests to link   → ReferencesController
//
// Only three things differ between them: where the candidates come from, how
// a row is drawn, and what gets inserted. Finding the run under the caret,
// ranking, the listbox, the keyboard and the insert-at-caret edit are the
// same either way, so they live here once and each trigger contributes a
// descriptor in TRIGGERS below.
//
// Both lists are fetched once per page load and filtered in the browser from
// then on. GitHub validates neither an `@login` nor a `#123` on write — it
// resolves them when it renders the comment — so this is a convenience, not a
// correctness surface: when a fetch fails no menu appears and typing carries
// on working.
//
// Keyboard: ArrowUp/ArrowDown move the highlight, Enter/Tab accept it, Escape
// closes the list without inserting anything.

const LIMIT = 8

// One shared promise per URL, so the dozens of composers, reply boxes and edit
// forms on a review page make one request between them. A failure is evicted
// (from inside the catch, once the promise has already settled) so the next
// keystroke retries instead of the page being stuck with an empty menu until
// someone reloads it.
const CACHE = new Map()

// Distinguishes one controller instance from the next. `aria-activedescendant`
// resolves an id document-wide, and this page holds one of these per thread.
let instances = 0

const SVG_NS = "http://www.w3.org/2000/svg"

// A pull request and an issue are drawn rather than spelled in the leading
// slot, the way GitHub's own menu draws them. The state is a separate word at
// the end of the row: nothing in Prism is carried by colour alone.
const ICONS = {
  pull_request: [
    [ "circle", { cx: "4", cy: "3.6", r: "1.8" } ],
    [ "circle", { cx: "4", cy: "12.4", r: "1.8" } ],
    [ "circle", { cx: "12", cy: "12.4", r: "1.8" } ],
    [ "path", { d: "M4 5.4v5.2" } ],
    [ "path", { d: "M12 10.6V6.6a2 2 0 0 0-2-2H7.4" } ],
    [ "path", { d: "M9 2.8 7.2 4.6 9 6.4" } ]
  ],
  issue: [
    [ "circle", { cx: "8", cy: "8", r: "6" } ],
    [ "circle", { cx: "8", cy: "8", r: "1.8" } ]
  ]
}

const STATUS_CLASS = {
  open: "text-added",
  draft: "text-ink-faint",
  merged: "text-brand",
  closed: "text-removed"
}

const TRIGGERS = {
  "@": {
    urlValue: "mentionablesUrl",
    label: "People to mention",
    // Login first, then real name: two accounts called "octocat-ci" and
    // "octocat-bot" are told apart by the login, so a hit there outranks a
    // hit on the name.
    fields: (person) => [ person.login, person.name ],
    insert: (person) => `@${person.login}`,
    draw: (row, person) => {
      if (person.avatar_url) {
        const avatar = document.createElement("img")
        avatar.src = person.avatar_url
        avatar.alt = ""
        avatar.loading = "lazy"
        avatar.className = "h-5 w-5 shrink-0 rounded-full"
        row.append(avatar)
      }

      const login = document.createElement("span")
      login.className = "shrink-0 font-medium"
      login.textContent = person.login
      row.append(login)

      if (person.name) {
        const name = document.createElement("span")
        name.className = "truncate text-ink-faint"
        name.textContent = person.name
        row.append(name)
      }
    }
  },

  "#": {
    urlValue: "referencesUrl",
    label: "Issues and pull requests",
    fields: (item) => [ String(item.number), item.title ],
    insert: (item) => `#${item.number}`,
    draw: (row, item) => {
      const kind = document.createElement("span")
      kind.className = "sr-only"
      kind.textContent = item.kind === "pull_request" ? "Pull request" : "Issue"
      row.append(kind)

      row.append(icon(item.kind, STATUS_CLASS[item.status] || "text-ink-faint"))

      const number = document.createElement("span")
      number.className = "shrink-0 tabular-nums text-ink-faint"
      number.textContent = `#${item.number}`
      row.append(number)

      const title = document.createElement("span")
      title.className = "truncate"
      title.textContent = item.title
      row.append(title)

      const status = document.createElement("span")
      status.className = "ml-auto shrink-0 text-xs text-ink-faint"
      status.textContent = item.status
      row.append(status)
    }
  }
}

// A trigger only opens a menu where a reference could actually start: at the
// beginning of the text, or after whitespace or an opening bracket or quote.
// Without this, `nick@example.com` offers a mention menu on the domain, and
// `abc#1` offers issues in the middle of a word — GitHub offers neither.
const BOUNDARY = /[\s([{<"']/

export default class extends Controller {
  static targets = [ "textarea", "list" ]
  static values = { mentionablesUrl: String, referencesUrl: String }

  connect() {
    this.matches = []
    this.trigger = null
    this.activeIndex = -1
    this.open = false
    this.token = 0

    this.uid = `autocomplete_${++instances}`
    this.listTarget.id = `${this.uid}_list`

    // Set here rather than in the three partials that render this: the roles
    // are the controller's contract, and a form that forgot one would be an
    // accessibility bug nobody sees.
    const textarea = this.textareaTarget
    textarea.setAttribute("role", "combobox")
    textarea.setAttribute("aria-autocomplete", "list")
    textarea.setAttribute("aria-haspopup", "listbox")
    textarea.setAttribute("aria-controls", this.listTarget.id)
    textarea.setAttribute("aria-expanded", "false")
  }

  // data-action="input->autocomplete#input"
  async input() {
    const found = this.match()
    if (!found) return this.close()

    const token = ++this.token
    const items = await this.candidates(found.trigger)

    // A newer keystroke started a newer lookup while this fetch was in
    // flight; that one owns the list now. Without this guard a slow first
    // fetch could paint results for a query the reviewer had already moved
    // past — or reopen a menu they had just dismissed.
    if (token !== this.token) return

    const still = this.match()
    if (!still || still.char !== found.char || still.query !== found.query) return this.close()

    this.trigger = found.trigger
    this.matches = rank(items, found.trigger, found.query)
    this.matches.length ? this.show() : this.close()
  }

  // data-action="keydown->autocomplete#keydown" — registered *before*
  // composer#keydown on the same textarea (see _composer_form), and calls
  // stopImmediatePropagation once it acts, so Escape closes this list instead
  // of also closing the whole composer and losing the draft.
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

  // data-action="blur->autocomplete#close". Clicking an option does not blur
  // the textarea — the option's mousedown handler prevents that — so this
  // only fires when focus really left, where a menu hanging over the page
  // would be a ghost of an editor nobody is in any more.
  close() {
    // Bumping the token here too, not only in input(): a fetch in flight when
    // Escape or a blur closed the menu would otherwise resolve afterwards,
    // find the same run still under the caret, and reopen the list the
    // reviewer had just dismissed.
    this.token += 1
    this.open = false
    this.activeIndex = -1
    this.matches = []
    this.listTarget.hidden = true
    this.listTarget.replaceChildren()
    this.textareaTarget.setAttribute("aria-expanded", "false")
    this.textareaTarget.removeAttribute("aria-activedescendant")
  }

  show() {
    this.open = true
    this.activeIndex = 0
    this.render()
  }

  render() {
    this.listTarget.hidden = false
    this.listTarget.setAttribute("aria-label", this.trigger.label)
    this.listTarget.replaceChildren(...this.matches.map((item, index) => this.option(item, index)))
    this.textareaTarget.setAttribute("aria-expanded", "true")
    this.highlight(this.activeIndex)
  }

  option(item, index) {
    const row = document.createElement("div")
    row.id = `${this.uid}_option_${index}`
    row.setAttribute("role", "option")
    row.setAttribute("aria-selected", "false")
    row.className = "flex cursor-pointer items-center gap-2 px-3 py-1.5 text-ink hover:bg-sunk"

    this.trigger.draw(row, item)

    row.addEventListener("mousedown", (event) => {
      // Keep the focus — and therefore the caret and the selection — in the
      // textarea. select() reads both.
      event.preventDefault()
      this.select(item)
    })
    row.addEventListener("mousemove", () => {
      if (this.activeIndex !== index) this.highlight(index)
    })

    return row
  }

  // Moves the highlight without rebuilding the rows, so the avatars don't
  // flicker as you arrow down and the element under the mouse survives its
  // own mousemove.
  highlight(index) {
    this.activeIndex = index

    const options = Array.from(this.listTarget.children)
    options.forEach((option, position) => {
      const on = position === index
      option.setAttribute("aria-selected", on ? "true" : "false")
      option.classList.toggle("bg-brand-soft", on)
      option.classList.toggle("text-brand", on)
      option.classList.toggle("text-ink", !on)
      option.classList.toggle("hover:bg-sunk", !on)
    })

    const active = options[index]
    if (!active) return

    this.textareaTarget.setAttribute("aria-activedescendant", active.id)
    // The list scrolls at about seven rows and shows eight, so arrowing to
    // the last one has to bring it into view.
    active.scrollIntoView({ block: "nearest" })
  }

  move(delta) {
    this.highlight((this.activeIndex + delta + this.matches.length) % this.matches.length)
  }

  select(item) {
    const textarea = this.textareaTarget
    const found = this.match()
    if (!found || !item) return

    const before = textarea.value.slice(0, found.start)
    const after = textarea.value.slice(textarea.selectionStart)
    const insertion = `${found.trigger.insert(item)} `

    textarea.value = `${before}${insertion}${after}`
    const cursor = before.length + insertion.length
    textarea.setSelectionRange(cursor, cursor)
    textarea.focus()
    textarea.dispatchEvent(new Event("input", { bubbles: true }))

    this.close()
  }

  // The trigger run immediately before the caret, or null when the caret is
  // not inside one.
  match() {
    const textarea = this.textareaTarget
    const caret = textarea.selectionStart
    const before = textarea.value.slice(0, caret)

    const run = before.match(/([@#])([\w-]*)$/)
    if (!run) return null

    const trigger = TRIGGERS[run[1]]
    const start = caret - run[0].length
    if (!trigger) return null
    if (start > 0 && !BOUNDARY.test(before[start - 1])) return null
    if (inCode(before)) return null

    return { char: run[1], trigger, query: run[2], start }
  }

  async candidates(trigger) {
    const url = this[`${trigger.urlValue}Value`]
    if (!url) return []

    if (!CACHE.has(url)) {
      CACHE.set(
        url,
        fetch(url, { headers: { Accept: "application/json" } })
          .then((response) => {
            if (!response.ok) throw new Error(`${url} answered ${response.status}`)
            return response.json()
          })
          .catch(() => {
            CACHE.delete(url)
            return []
          })
      )
    }

    return CACHE.get(url)
  }
}

// Prefix match first, then word-start, then anywhere, and a hit on the first
// field (login, number) ahead of the same kind of hit on the second (real
// name, title). Within a tier the server's order survives, because Array#sort
// is stable: alphabetical for people, most-recently-touched for issues and
// pull requests, which is what an empty query wants to show.
function rank(items, trigger, query) {
  if (!query) return items.slice(0, LIMIT)

  const needle = query.toLowerCase()
  const scored = []

  items.forEach((item) => {
    let best = null

    trigger.fields(item).forEach((raw, index) => {
      if (!raw) return

      const field = String(raw).toLowerCase()
      let tier = null
      if (field.startsWith(needle)) tier = 0
      else if (field.split(/[^a-z0-9]+/).some((word) => word.startsWith(needle))) tier = 1
      else if (field.includes(needle)) tier = 2
      if (tier === null) return

      const score = tier * 2 + Math.min(index, 1)
      if (best === null || score < best) best = score
    })

    if (best !== null) scored.push({ score: best, item })
  })

  return scored.sort((a, b) => a.score - b.score).slice(0, LIMIT).map((entry) => entry.item)
}

// A reference inside code renders as literal text, so offering to insert one
// there offers something that cannot work. An odd number of ``` fences before
// the caret puts us inside a block; failing that, an odd number of backticks
// on the current line puts us inside a span.
function inCode(before) {
  if ((before.match(/^ {0,3}```/gm) || []).length % 2 === 1) return true

  const line = before.slice(before.lastIndexOf("\n") + 1)
  return (line.match(/`/g) || []).length % 2 === 1
}

function icon(kind, className) {
  const svg = document.createElementNS(SVG_NS, "svg")
  svg.setAttribute("viewBox", "0 0 16 16")
  svg.setAttribute("fill", "none")
  svg.setAttribute("stroke", "currentColor")
  svg.setAttribute("stroke-width", "1.5")
  svg.setAttribute("stroke-linecap", "round")
  svg.setAttribute("stroke-linejoin", "round")
  svg.setAttribute("aria-hidden", "true")
  svg.setAttribute("class", `h-4 w-4 shrink-0 ${className}`)

  ICONS[kind === "pull_request" ? "pull_request" : "issue"].forEach(([ name, attributes ]) => {
    const shape = document.createElementNS(SVG_NS, name)
    Object.entries(attributes).forEach(([ key, value ]) => shape.setAttribute(key, value))
    svg.append(shape)
  })

  return svg
}
