# Source notes

## build.zig

Bridge dependencies are emitted in the listed order. The user's `bridge.js` is
emitted last so it can override dependency symbols. Fonts are copied into
`dist/fonts/` and loaded before the app's `init` runs.

## src/bind/bind.zig

The exchange buffer is shared with JavaScript and reused for successive strings;
callers must copy data they need to retain. Callback ID zero denotes failure or
no callback, and registered IDs are not reused.

## src/web/ime.zig

The hidden textarea holds focus during text input. Set it active while a text
field is focused, update its spot with the caret's canvas-relative CSS position
and line height, and poll once per frame. Printable keys use the input typed-text
path. The update cursor is a byte offset; an empty commit after a composition
means cancellation. Event text aliases the poll scratch buffer. Records that do
not fit in scratch stay queued; records read into scratch beyond the output
array's capacity are discarded.
