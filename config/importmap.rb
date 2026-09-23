# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"

# Mermaid 11.17.2, for diagrams in a reviewed file — `dist/mermaid.min.js`,
# downloaded into vendor/javascript by hand rather than by `bin/importmap pin`.
# jspm resolves mermaid into several hundred separate modules, which would mean
# several hundred pins and several hundred requests; this build is one
# self-contained file with no dynamic `import()` in it, so it is one request and
# nothing to resolve against a CDN we don't pin.
#
# `preload: false` is the whole point of the pin. Nothing fetches 3.5 MB until a
# page actually holds a ```mermaid fence; most pull requests hold none, and
# those pages pay ~70 bytes of importmap JSON. What the entry is *for* is
# `import.meta.resolve("mermaid")` in mermaid_controller.js, which is how that
# file finds this digested path without the version being written down twice —
# the bundle is a classic script rather than a module, so it is loaded with a
# <script> tag and sets `globalThis.mermaid`. See the comment on `loadMermaid`.
pin "mermaid", to: "mermaid.min.js", preload: false
