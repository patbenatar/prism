import { Controller } from "@hotwired/stimulus"

// Draws a ```mermaid fence as a diagram, beside the <pre> rather than instead
// of it.
//
// The <pre> never leaves the DOM. It carries `data-sourcepos`, it is what the
// block's gutter "+" anchors a comment to, and it is the whole block when
// JavaScript is off — so the diagram is a sibling that the wrapper shows or
// hides, and the toggle below it swaps which one you are looking at.
//
// Three things here are load-bearing and are explained where they happen:
// the library is fetched only when a fence exists (`loadMermaid`), every
// <style> mermaid makes is given the *document's* CSP nonce rather than the
// meta tag's current value (`DOCUMENT_NONCE`), and the SVG is walked against an
// allowlist before it reaches the page (`sanitize`) — the diagram source came
// out of somebody else's repository and Markdown::Sanitizer, which is
// server-side, never sees it.

// ── The library ────────────────────────────────────────────────────────────
//
// One fetch per page however many diagrams it holds, and no fetch at all on a
// page with none: this module only runs when the server wrapped a fence, and
// the import is inside the function rather than at the top of the file.
//
// The vendored bundle is esbuild's IIFE build, which is a *classic* script: it
// keeps its namespace in a top-level `var` and reads it back off `globalThis`
// on the last line. Under `import()` that `var` is module-scoped instead of
// global, so the last line throws and `globalThis.mermaid` is never assigned —
// so it is loaded the way it was built to be, with a <script> tag.
//
// The importmap is still the one place the version lives: `import.meta.resolve`
// asks it where "mermaid" is, which is the digested path under /assets. The
// pin's `preload: false` is what keeps this the only thing that ever fetches it.
let libraryPromise = null

function loadMermaid() {
  libraryPromise ||= new Promise((resolve, reject) => {
    const script = document.createElement("script")
    script.src = import.meta.resolve("mermaid")
    script.nonce = DOCUMENT_NONCE
    script.addEventListener("load", () => resolve(globalThis.mermaid), { once: true })
    script.addEventListener("error", () => reject(new Error("the diagram library didn't load")), {
      once: true
    })
    document.head.appendChild(script)
  })
  return libraryPromise
}

// ── Rendering happens one at a time ────────────────────────────────────────
//
// `mermaid.render` is not reentrant: it keeps a module-level id counter and
// reuses one scratch element, and we wrap `document.createElement` around the
// call (see `withNoncedStyles`), which two overlapping renders would unwrap
// from under each other. A page with nine diagrams draws them in order.
let chain = Promise.resolve()
let sequence = 0

function enqueue(work) {
  const result = chain.then(work, work)
  chain = result.then(
    () => {},
    () => {}
  )
  return result
}

// ── Offscreen stage ────────────────────────────────────────────────────────
//
// Mermaid measures text with `getBBox`, which needs the diagram to be laid out
// by the real engine with the real fonts — a detached node measures zero and
// every label comes out overlapping. So it draws into a stage that is in the
// document but off the side of it: `visibility: hidden` still lays out,
// `display: none` would not. The class lives in application.css so that this
// controller writes no inline styles of its own.
let stage = null

function renderStage() {
  if (!stage?.isConnected) {
    stage = document.createElement("div")
    stage.className = "md-mermaid-stage"
    stage.setAttribute("aria-hidden", "true")
    document.body.appendChild(stage)
  }
  return stage
}

// ── CSP ────────────────────────────────────────────────────────────────────
//
// `style-src` is 'self' plus a per-request nonce, and mermaid builds the
// diagram's stylesheet as a <style> element which it inserts into the live
// document to measure the laid-out result. Unnonced, that element is blocked:
// the page still renders, the diagram simply comes out unstyled, and the only
// evidence is a console violation — which is exactly the failure
// `assert_no_csp_violations` exists to catch.
//
// Mermaid has no configuration for a nonce — the string does not appear in the
// bundle outside an attribute-name table — so we stamp one on at the two points
// a stylesheet comes into being and put both back in `finally`.
//
// It takes two, because a nonce does not survive being written out as text. The
// CSP nonce-hiding rule empties the `nonce` content attribute once an element
// is in a document, keeping the real value in a slot JavaScript cannot read. So
// when mermaid serializes the finished SVG and hands the string to its own
// DOMPurify pass (which `securityLevel: "strict"` turns on), the <style> inside
// that string arrives as `nonce=""` and re-parsing it is a second violation, in
// mermaid's code rather than ours. Putting the nonce back into the string on
// the way into any parse closes it — and covers `adopt`'s parse below too.
//
// Both patches are narrow: only <style> is touched, only while one render is in
// flight, and `enqueue` guarantees renders never overlap.
function withNoncedStyles(nonce, run) {
  const create = document.createElement
  const parse = DOMParser.prototype.parseFromString

  document.createElement = function (tagName, options) {
    const element = create.call(this, tagName, options)
    if (nonce && String(tagName).toLowerCase() === "style") {
      element.setAttribute("nonce", nonce)
    }
    return element
  }

  DOMParser.prototype.parseFromString = function (markup, type, ...rest) {
    return parse.call(this, nonceStyleTags(markup, nonce), type, ...rest)
  }

  return Promise.resolve()
    .then(run)
    .finally(() => {
      document.createElement = create
      DOMParser.prototype.parseFromString = parse
    })
}

// Rewrites `<style …>` to carry the nonce. It can only add an attribute to a
// tag that is already there — it cannot introduce an element — and a base64
// nonce needs no escaping inside a quoted attribute value.
//
// `String(markup)` rather than the argument itself: DOMPurify runs its input
// through a Trusted Types policy first, so what arrives at `parseFromString` is
// a TrustedHTML object and not a string at all. Handing the plain string back is
// fine — Prism sets no `require-trusted-types-for` directive.
function nonceStyleTags(markup, nonce) {
  if (!nonce) return markup

  return String(markup).replace(
    /<style\b([^>]*)>/gi,
    (_match, attributes) => `<style${attributes.replace(/\snonce\s*=\s*(["'])[^"']*\1/gi, "")} nonce="${nonce}">`
  )
}

// Did the diagram's own stylesheet actually take effect?
//
// A <style> the policy refused is not an error anywhere: the element is in the
// DOM, the SVG is in the DOM, and the only difference is that every shape falls
// back to SVG's default paint — solid black, with labels drawn in a font other
// than the one they were measured in. That is a broken diagram that looks to
// every automated check like a working one, which is how it reached production.
//
// `sheet` is null on an element whose CSS was never parsed, so this is the
// browser's own answer to "did you accept this?". Throwing hands the block to
// `fail`, which shows the source and says so.
function assertStylesApplied(svg) {
  const styles = [...svg.querySelectorAll("style")]
  if (styles.length > 0 && styles.every((style) => !style.sheet)) {
    throw new Error("the browser refused the diagram's stylesheet")
  }
}

// The nonce the DOCUMENT's policy was delivered with — read once, when this
// module is evaluated, and deliberately never read again.
//
// `<meta name="csp-nonce">` is not a stable fact about the page. A Turbo Drive
// visit swaps <body> and rewrites that meta to the *new* response's nonce, so
// the server can validate what it sends next. But a Drive visit does not create
// a new document, and a Content Security Policy belongs to the document: the
// policy still being enforced is the one that arrived with the original full
// page load. So after any Drive visit the meta holds a nonce the browser has
// never heard of, and stamping it on a <style> gets that element blocked.
//
// This is what shipped broken. Every test here reached the page with Capybara's
// `visit` — a real navigation, new document, meta and policy agreeing — while
// every reviewer reaches it by clicking, which is a Drive visit. The diagram
// then keeps its geometry and loses all of its paint: black nodes, black
// labels, and labels measured in one font but drawn in another because the
// stylesheet that sets the font never applied either.
//
// Module evaluation happens once per document, during the initial load, which
// is exactly when the meta and the enforced policy still agree. `adopt` checks
// the result rather than trusting this reasoning — see `assertStylesApplied`.
const DOCUMENT_NONCE = document.querySelector('meta[name="csp-nonce"]')?.content || ""

// ── Sanitizing the SVG ─────────────────────────────────────────────────────
//
// The diagram source is whatever the reviewed repository contains. Mermaid
// runs its own DOMPurify pass under `securityLevel: "strict"`, and mermaid has
// a history of XSS through labels and link syntax, so this is the second layer
// — the same argument Markdown::Sanitizer makes server-side, applied to markup
// the server never sees.
//
// It is an allowlist, not a blocklist: anything not named here is removed
// whole, so a tag nobody thought of is dropped rather than passed through.
const ALLOWED_ELEMENTS = new Set([
  // SVG structure and shapes mermaid actually emits.
  "svg", "g", "defs", "symbol", "marker", "clippath", "mask", "pattern",
  "lineargradient", "radialgradient", "stop", "filter", "fegaussianblur",
  "feoffset", "feflood", "fecomposite", "femerge", "femergenode",
  "fecolormatrix", "path", "line", "polyline", "polygon", "rect", "circle",
  "ellipse", "text", "tspan", "textpath", "title", "desc", "style", "a", "use",
  "image", "foreignobject", "switch",
  // The HTML mermaid puts inside a <foreignObject> label.
  "div", "span", "p", "br", "strong", "b", "em", "i", "code", "sup", "sub",
  "ul", "ol", "li", "table", "thead", "tbody", "tr", "th", "td", "label", "hr"
])

// Everything that can name a resource. Anything else is a presentation
// attribute and cannot execute.
const URL_ATTRIBUTES = new Set(["href", "src", "xlink:href"])

// The CSS properties a diagram is allowed to set on one of its own elements.
//
// This attribute used to be dropped whole, on the reasoning that mermaid puts
// its styling in the diagram's <style> element and an attribute could only be
// untrusted CSS. That was wrong, and wrong in a way that quietly broke real
// diagrams: mermaid relies on the `style` attribute for painting that has no
// stylesheet rule behind it at all. A sequence diagram's self-message carries
// `style="fill: none;"` and nothing else says so, so without it the arc
// inherits `fill` from the root rule and renders as a filled blob. A pie
// chart's slice colours are *only* here. So are a state diagram's edge fills,
// a `classDef`'s `fill … !important`, and the table-cell layout of a journey
// diagram's HTML labels.
//
// So the attribute stays and its contents are filtered instead. Two things make
// that safe. The properties below are the ones that paint a shape or set type;
// what is deliberately absent is everything that could escape the figure —
// `position`, `z-index`, `transform`, `content`, `animation`, `background`,
// `pointer-events`, `cursor`, `filter`, `clip-path`, `mask`. And values are
// checked for `url()`, which is restricted to same-document fragments, so a
// repository cannot use a diagram to fetch anything.
//
// Nothing about the policy changes: `style-src-attr` is already
// `'unsafe-inline'`, because a nonce cannot apply to an attribute. See
// DESIGN.md §4 — that section used to say the label pills were the only inline
// style Prism emits, and now says this too.
const STYLE_PROPERTIES = new Set([
  // Paint.
  "fill", "fill-opacity", "fill-rule", "stroke", "stroke-width",
  "stroke-dasharray", "stroke-dashoffset", "stroke-linecap", "stroke-linejoin",
  "stroke-miterlimit", "stroke-opacity", "opacity", "color", "paint-order",
  "shape-rendering", "vector-effect", "marker-start", "marker-mid", "marker-end",
  // Type.
  "font", "font-family", "font-size", "font-style", "font-variant",
  "font-weight", "letter-spacing", "word-spacing", "line-height",
  "text-anchor", "text-align", "text-decoration", "text-overflow",
  "dominant-baseline", "alignment-baseline", "white-space", "word-break",
  "overflow-wrap",
  // The box a <foreignObject> label lays itself out in.
  "display", "visibility", "width", "height", "min-width", "max-width",
  "min-height", "max-height", "margin", "margin-top", "margin-right",
  "margin-bottom", "margin-left", "padding", "padding-top", "padding-right",
  "padding-bottom", "padding-left", "vertical-align", "text-indent", "overflow"
])

// A `url()` in a value may point inside this same diagram and nowhere else, so
// a diagram cannot become a beacon. This matches a `url(` that is *not*
// followed by a fragment, so "no match" means every reference is a local one.
const FOREIGN_URL = /url\(\s*(?!["']?#)/i

// Filters a `style` attribute in place.
//
// The browser has already parsed it — this runs on a DOMParser document, so the
// declarations arrive normalised and anything malformed has been dropped
// already. That means we never build CSS text out of repository content: we
// read the properties the parser accepted and remove the ones we do not want.
// `!important` survives, which matters, because that is how a `classDef` colour
// beats the diagram's own stylesheet.
function sanitizeStyle(element) {
  const style = element.style

  for (const property of [ ...style ]) {
    const value = style.getPropertyValue(property)
    if (!STYLE_PROPERTIES.has(property) || FOREIGN_URL.test(value)) {
      style.removeProperty(property)
    }
  }

  if (style.length === 0) element.removeAttribute("style")
}

// A fragment into this same document, or a page you could have clicked in the
// Markdown around it. Deliberately no `javascript:`, `data:` or `blob:`.
const SAFE_URL = /^(?:https?:\/\/|mailto:|#)/i

// Mermaid sizes the diagram with `width="100%"` and a `max-width` style
// ATTRIBUTE, which makes it shrink to whatever column it lands in. At phone
// width that turns a flowchart into an illegible thumbnail, so `adopt` throws
// both away and sets the drawing's own size from its viewBox instead: the
// frame scrolls and the labels stay readable, which is what a wide table and a
// wide <pre> already do here (DESIGN §9).
//
// Four numbers, nothing else. If a diagram type ever produces no viewBox, the
// `max-width` number is the fallback — also just a number.
const VIEW_BOX = /^\s*[\d.eE+-]+[\s,]+[\d.eE+-]+[\s,]+([\d.]+)[\s,]+([\d.]+)\s*$/
const MAX_WIDTH = /max-width:\s*([\d.]+)px/i

function sanitize(element) {
  for (const child of Array.from(element.children)) {
    if (!ALLOWED_ELEMENTS.has(child.localName.toLowerCase())) {
      child.remove()
      continue
    }
    sanitizeAttributes(child)
    sanitize(child)
  }
}

function sanitizeAttributes(element) {
  const name = element.localName.toLowerCase()

  for (const attribute of Array.from(element.attributes)) {
    const attributeName = attribute.name.toLowerCase()

    // Every event handler content attribute begins with "on", in HTML and in
    // SVG alike (onclick, onbegin, onrepeat).
    if (attributeName.startsWith("on")) {
      element.removeAttributeNode(attribute)
      continue
    }

    // Not dropped wholesale — see `sanitizeStyle`.
    if (attributeName === "style") {
      sanitizeStyle(element)
      continue
    }

    if (URL_ATTRIBUTES.has(attributeName)) {
      if (!SAFE_URL.test(attribute.value.trim())) element.removeAttributeNode(attribute)
      continue
    }

    // A namespaced attribute nobody asked for.
    if (attributeName.includes(":") && !/^(?:xlink|xml):/.test(attributeName)) {
      element.removeAttributeNode(attribute)
    }
  }

  // A link out of a diagram opens like every other link in the prose.
  if (name === "a" && element.hasAttribute("href")) {
    element.setAttribute("target", "_blank")
    element.setAttribute("rel", "noopener noreferrer")
  }
}

// Every id the diagram carries is namespaced, for the reason Markdown::
// Sanitizer namespaces the ones in the document: the page finds its own
// elements by id — Turbo Stream targets, `getElementById` — and a repository
// that draws a node called `pending_tray` would otherwise be able to claim one.
//
// Both sides are rewritten, so the diagram still resolves internally: `url(#…)`
// and `href="#…"` in attributes, and the `#<id>` selectors mermaid writes into
// the diagram's own stylesheet. The reference pattern is built from the ids
// that are actually present, which is why a hex colour like `#fff` in that
// stylesheet is left alone unless something is genuinely called `fff`.
const ID_PREFIX = "user-content-"

function namespaceIds(svg) {
  // Already-prefixed ids are left alone, the same guard Markdown::Sanitizer
  // keeps, so nothing ends up `user-content-user-content-…`.
  const carriers = [svg, ...svg.querySelectorAll("[id]")].filter(
    (element) => element.getAttribute("id") && !element.getAttribute("id").startsWith(ID_PREFIX)
  )
  const originals = [...new Set(carriers.map((element) => element.getAttribute("id")))]
  if (originals.length === 0) return

  for (const element of carriers) {
    element.setAttribute("id", ID_PREFIX + element.getAttribute("id"))
  }

  const alternatives = originals
    .slice()
    .sort((a, b) => b.length - a.length)
    .map((id) => id.replace(/[.*+?^${}()|[\]\\-]/g, "\\$&"))
  const reference = new RegExp(`#(${alternatives.join("|")})(?![\\w.:-])`, "g")
  const rewrite = (value) => value.replace(reference, (_match, id) => `#${ID_PREFIX}${id}`)

  for (const element of [svg, ...svg.querySelectorAll("*")]) {
    for (const attribute of Array.from(element.attributes)) {
      if (attribute.name.toLowerCase() === "id") continue
      if (attribute.value.includes("#")) attribute.value = rewrite(attribute.value)
    }
    if (element.localName.toLowerCase() === "style") {
      element.textContent = rewrite(element.textContent)
    }
  }
}

// ── Theme ──────────────────────────────────────────────────────────────────
//
// The colours come out of the stylesheet rather than being restated here, so a
// diagram follows the same tokens as everything around it and follows them into
// dark mode. A token is a `light-dark()` pair, and `getPropertyValue` hands back
// the pair rather than the side that won, so each one is painted onto a probe
// and read back as a used value — the same trick DarkModeTest uses.
let probe = null

function resolved(property, token) {
  if (!probe?.isConnected) {
    // Offscreen for the same reason the stage is, and laid out for the same
    // reason: a token has to be painted before it resolves.
    probe = document.createElement("span")
    probe.className = "md-mermaid-stage"
    document.body.appendChild(probe)
  }
  probe.style.setProperty(property, `var(${token})`)
  return getComputedStyle(probe).getPropertyValue(property)
}

function color(token) {
  return resolved("color", token)
}

// Which side of every `light-dark()` pair the browser actually took, asked of
// the canvas itself rather than re-deriving it from `prefers-color-scheme` and
// `data-theme`. The stylesheet decides; this reads the decision.
function isDark(canvas) {
  const [red, green, blue] = (canvas.match(/[\d.]+/g) || [255, 255, 255]).map(Number)
  return 0.2126 * red + 0.7152 * green + 0.0722 * blue < 128
}

function themeConfig() {
  const canvas = color("--color-canvas")
  const surface = color("--color-surface")
  const sunk = color("--color-sunk")
  const ink = color("--color-ink")
  const inkFaint = color("--color-ink-faint")
  const line = color("--color-line")
  const lineStrong = color("--color-line-strong")
  const brand = color("--color-brand")
  const brandSoft = color("--color-brand-soft")
  const modified = color("--color-modified")
  const modifiedSoft = color("--color-modified-soft")

  return {
    // `base` is the only theme that derives everything from what it is given;
    // the named themes hard-code their own palette.
    theme: "base",
    darkMode: isDark(canvas),
    fontFamily: getComputedStyle(document.documentElement).getPropertyValue("--font-display").trim(),
    themeVariables: {
      darkMode: isDark(canvas),
      background: surface,
      // A node is a raised thing on the panel behind it, which in this system
      // means `sunk`: darker than the surface on paper, lighter than it on the
      // dark canvas, so it reads as a lift in both (see the token comment in
      // application.css).
      primaryColor: sunk,
      primaryTextColor: ink,
      primaryBorderColor: brand,
      secondaryColor: brandSoft,
      tertiaryColor: canvas,
      mainBkg: sunk,
      nodeBorder: lineStrong,
      clusterBkg: sunk,
      clusterBorder: line,
      lineColor: inkFaint,
      textColor: ink,
      titleColor: ink,
      edgeLabelBackground: surface,
      noteBkgColor: modifiedSoft,
      noteTextColor: ink,
      noteBorderColor: modified,
      fontSize: "15px"
    }
  }
}

// ── Redrawing when the colour scheme changes ───────────────────────────────
//
// One media query listener and one attribute observer for the page, not a pair
// per diagram. `data-theme` on <html> is the manual override; the media query
// is the device preference underneath it.
const mounted = new Set()

function watchColorScheme() {
  if (watchColorScheme.watching) return
  watchColorScheme.watching = true

  const redrawAll = () => mounted.forEach((controller) => controller.draw())

  window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", redrawAll)
  new MutationObserver(redrawAll).observe(document.documentElement, {
    attributes: true,
    attributeFilter: ["data-theme"]
  })
}

// ── The controller ─────────────────────────────────────────────────────────

export default class extends Controller {
  static targets = ["source", "figure", "error", "toggle"]

  connect() {
    mounted.add(this)
    watchColorScheme()
    this.draw()
  }

  disconnect() {
    mounted.delete(this)
  }

  // data-action on the button the controller adds once a diagram exists.
  toggle(event) {
    event?.preventDefault()
    const showingSource = this.element.dataset.mermaidState === "source"
    this.state(showingSource ? "diagram" : "source")
  }

  // The button's own label carries the state — "Show source" means you are
  // looking at the diagram. That is the whole story, so it gets no
  // `aria-expanded`: this is two views of one thing, not a disclosure.
  state(value) {
    this.element.dataset.mermaidState = value
    if (!this.hasToggleTarget) return

    this.toggleTarget.textContent = value === "source" ? "Show diagram" : "Show source"
  }

  get source() {
    return this.sourceTarget.textContent || ""
  }

  async draw() {
    if (!this.hasSourceTarget || !this.hasFigureTarget) return

    const text = this.source
    if (!text.trim()) return

    try {
      const mermaid = await loadMermaid()
      const svg = await enqueue(() => this.render(mermaid, text))
      this.adopt(svg)
    } catch (error) {
      this.fail(error)
    }
  }

  async render(mermaid, text) {
    mermaid.initialize({
      startOnLoad: false,
      // Never "loose" or "antiscript". Strict encodes HTML in labels, runs
      // mermaid's own DOMPurify pass over the finished SVG, and turns off
      // `click` bindings entirely — we never call `bindFunctions`, so nothing
      // from the diagram can attach a handler even if one were produced.
      securityLevel: "strict",
      // HTML labels are a <foreignObject> full of markup built from the
      // diagram source. SVG <text> is the same label with none of that.
      htmlLabels: false,
      flowchart: { htmlLabels: false },
      class: { htmlLabels: false },
      // Mermaid's own error diagram would be drawn into the page; we would
      // rather show the source with a note saying why.
      suppressErrorRendering: true,
      logLevel: "fatal",
      ...themeConfig()
    })

    // Throws on a syntax error, before anything is drawn.
    await mermaid.parse(text)

    const id = `prism-mermaid-${(sequence += 1)}`
    const stage = renderStage()

    const { svg } = await withNoncedStyles(DOCUMENT_NONCE, () =>
      mermaid.render(id, text, stage)
    )
    stage.replaceChildren()
    return svg
  }

  // Parse, scrub, then move into the page. The string is parsed into a
  // *separate* document, so nothing runs and nothing loads while it is being
  // examined; only the scrubbed tree is imported into this one.
  adopt(svg) {
    const nonce = DOCUMENT_NONCE
    // The nonce goes in before the parse, not after: parsing is when the
    // stylesheet is created and so when the policy is checked. Our own call
    // site, so no patch — `nonceStyleTags` is enough.
    const parsed = new DOMParser().parseFromString(nonceStyleTags(svg, nonce), "text/html")
    const root = parsed.body.querySelector("svg")
    if (!root) throw new Error("mermaid produced no SVG")

    const box = root.getAttribute("viewBox")?.match(VIEW_BOX)
    const fallbackWidth = root.getAttribute("style")?.match(MAX_WIDTH)?.[1]

    sanitizeAttributes(root)
    sanitize(root)
    namespaceIds(root)

    // How big the drawing is on the page is Prism's decision, not the
    // diagram's: mermaid sizes the root with `width="100%"` and a `max-width`,
    // which shrinks a wide diagram into an illegible thumbnail. Everything
    // *inside* keeps its painting declarations; only the root loses its style.
    root.removeAttribute("style")

    const adopted = document.importNode(root, true)
    // Importing makes new elements; re-stamp rather than trust the copy.
    for (const style of adopted.querySelectorAll("style")) style.setAttribute("nonce", nonce)
    // A picture, named. Mermaid carries an `accTitle` through as <title> when
    // the diagram declares one; when it does not, a reviewer on a screen
    // reader still gets told what this is and that the toggle below it will
    // read out the source instead.
    adopted.setAttribute("role", "img")
    if (!adopted.querySelector("title")?.textContent?.trim()) {
      adopted.setAttribute("aria-label", "Diagram — use the button below to read its source")
    }

    if (box) {
      adopted.setAttribute("width", Number(box[1]))
      adopted.setAttribute("height", Number(box[2]))
    } else if (fallbackWidth) {
      // Through CSSOM rather than as a style attribute, and from a number this
      // side matched against `[\d.]+`, so no repository string is ever parsed
      // as CSS.
      adopted.style.maxWidth = `${Number(fallbackWidth)}px`
    }

    this.figureTarget.replaceChildren(adopted)
    assertStylesApplied(adopted)
    this.errorTarget.hidden = true
    this.addToggle()
    this.state("diagram")
  }

  // A malformed fence is one bad diagram, not a bad page: the block keeps its
  // gutter, the source stays readable, and the note says what happened.
  fail(error) {
    this.figureTarget.replaceChildren()

    // Two parts, because they are two different things: our sentence, and
    // mermaid's own parse error. The second goes in mono with its newlines
    // kept, since it points at the offending column with a caret that only
    // lines up in a monospaced face.
    const sentence = document.createElement("span")
    sentence.textContent = "Prism couldn't draw this diagram."
    this.errorTarget.replaceChildren(sentence)

    const detail = String(error?.message || error || "").trim()
    if (detail) {
      const code = document.createElement("code")
      code.className = "md-mermaid-error-detail"
      code.textContent = detail
      this.errorTarget.appendChild(code)
    }

    this.errorTarget.hidden = false
    this.state("source")
    if (this.hasToggleTarget) this.toggleTarget.remove()
  }

  addToggle() {
    if (this.hasToggleTarget) return

    const button = document.createElement("button")
    button.type = "button"
    button.className = "md-mermaid-toggle"
    button.dataset.mermaidTarget = "toggle"
    button.dataset.action = "mermaid#toggle"
    button.dataset.testid = "mermaid-toggle"
    this.element.appendChild(button)
  }
}
