# A11y DOM mirror v2 (nested ARIA tree, actions back, focus sync)

**Audience**: Teak maintainers. **Version**: unreleased (additive to the v0.10.0 bridge; no version bump in the PR,
see docs/VERSIONING.md). Supersedes the wire format in `v0.10.0-a11y-bridge.md`.

## What changed

* `src/gen/js/a11y.js` (embedded, emitted only when a build imports the a11y externs) replaces the inline
  one-liner. It mirrors Teak's tree into a **nested** DOM subtree under `#zunk-a11y-root`, positioned over the
  canvas (invisible, `pointer-events: none`), diffed by `cmd_index`.
* Wire format v2: 64-byte records (`cmd_index, role, label, bounds, state, flags, value, selection, parent, level`),
  ARIA-named role codes (button, textbox, checkbox, radio, slider, combobox, listbox, option, menu, menuitem, tablist,
  tab, tree, treeitem, table, row, cell, progressbar, status, alert, list, listitem, toolbar, heading, menubar,
  columnheader, link, dialog, ...). The table lives in `js/a11y.js` and Teak's `src/platform/wasm.zig`.
* **Actions back**: new extern `__zunk_poll_a11y_actions(recs, cap, strs, str_cap) -> count`. DOM `click` on a
  mirrored element, DOM `focus` (AT moving focus) and an `input` event with no recent key press (AT setting a
  value) are queued and drained once per frame; Teak turns them into ordinary input. The DOM is derived state.
* **Focus sync both ways**: Teak's focused node gets DOM focus; keys that activate a native control (Enter/Space on
  a mirrored button) do not also reach the app's keyboard path.
* Live regions: `status` / `alert` / hinted groups get `aria-live`; text updates in place keep the element identity.
* **`typedChars` cap 64 -> 255 bytes/frame** (`InputState.typed_chars` is now `[255]u8`) and dropping is no longer
  silent: one `console.warn` per frame.
* `examples/a11y-demo` rewritten for v2 (nested tree, tabs, textbox with selection, live status, action counters).

## Testing

Teak's `tools/a11yprobe.mjs` loads `examples/todo` / `examples/notes` web builds in headless Chromium, reads the
browser accessibility tree and drives the app only through the mirror.

## Caveat found while wiring it

Teak's wasm host gated the extern call on `@hasDecl(externs, ...)`, which is false for non-`pub` decls, so v0.10's
mirror was never actually called from Teak. Fixed on the Teak side (the call is unconditional).
