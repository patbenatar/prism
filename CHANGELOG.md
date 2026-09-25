# Changelog

Newest first. Written for people using Prism, not for how it is built.

## 2026-09-25

- **You stay signed in.** GitHub's sign-in only lasted eight hours, so anyone
  who signed in before lunch found Prism refusing to load anything by
  mid-afternoon — and had to sign in again, every single day. Prism now renews
  it quietly in the background. You should never see a sign-in screen again
  unless you sign out or revoke Prism's access on GitHub.
- **Watched repositories keep working overnight.** The same eight hours is why
  a repository could stop getting its review links some time after you closed
  your laptop and start again the next morning. Watching no longer depends on
  anyone being at their desk.
- **Watching a repository now heals itself.** If GitHub refuses Prism's access
  for a while, the pull requests that were opened or pushed to meanwhile no
  longer lose their review link for good: Prism re-checks every watched
  repository's open pull requests on a schedule, and again the moment you sign
  in, and adds any link that should be there and isn't.
- **Fixed: watching a busy repository used to stop working before a quiet
  one.** Prism gave up after a fixed number of failed deliveries, so the more
  a repository was used, the faster it burned through them. It now gives up
  only after a month of not working at all, whatever the traffic.
- **Fixed: a repository Prism had given up on could not be fixed by signing
  in**, even when a refused sign-in was the recorded reason it stopped.

## 2026-09-24

- **Fixed: a sequence diagram's self-messages drew as filled blobs.** The arc
  that leaves a lifeline and returns to it is now a thin stroked curve, as it
  should be. The same fix restores pie chart slice colours, state diagram edges
  and `classDef` fills, which were all being dropped.
- **Fixed: diagrams were unpainted after clicking through to a file.** A
  diagram reached by navigating within Prism drew as solid black boxes with
  black labels. It now takes the page's own colours however you got there.

## 2026-09-23

- **Mermaid diagrams are drawn**, not shown as source. A ```mermaid fence in a
  reviewed file renders as a diagram in the page's own colours, follows dark
  mode, and can still be commented on — the source is a click away under it.
  A diagram that won't parse falls back to its source with the reason.

## 2026-09-19

- **Sign in with GitHub** and browse the repositories you can access, their
  pull requests, and each pull request's Markdown files.
- **Read a pull request's Markdown rendered**, with changed blocks marked in
  the gutter, deleted content shown as collapsible strips, and existing GitHub
  comments placed next to the block they belong to.
- **Comment on rendered blocks**: paragraphs, headings, list items, table rows,
  code blocks. Comments post to GitHub as real review comments anchored to the
  right source lines. Blocks outside the diff become file-level comments that
  quote the block.
- **Full review flow**: single comments, pending reviews with Approve /
  Request changes / Comment, replies, edit and delete, reactions, resolve and
  unresolve, @-mention autocomplete, and Markdown preview.
