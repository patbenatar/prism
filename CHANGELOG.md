# Changelog

Newest first. Written for people using Prism, not for how it is built.

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
