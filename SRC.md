# Source notes

## build.zig

Bridge dependencies are emitted in the listed order. The user's `bridge.js` is
emitted last so it can override dependency symbols. Fonts are copied into
`dist/fonts/` and loaded before the app's `init` runs.

## src/bind/bind.zig

The exchange buffer is shared with JavaScript and reused for successive strings;
callers must copy data they need to retain. Callback ID zero denotes failure or
no callback, and registered IDs are not reused.
