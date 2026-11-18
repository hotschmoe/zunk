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

## src/web/input.zig

Pointer and viewport coordinates and wheel deltas are CSS pixels; wheel deltas
are positive down and right, and line or page modes are converted to pixels.
Trackpad pinch arrives with Ctrl set. The canvas backing dimensions scale CSS
dimensions by device pixel ratio. Modifiers reflect the most recent event;
typed text consists of whole UTF-8 code points, excluding control characters and
Ctrl/Cmd chords. The meta modifier is Cmd on macOS and the Windows key elsewhere.

## src/web/audio.zig

Audio decoding is asynchronous. Loading audio from bytes returns a handle before
decoding completes; poll `isReady()` before playing it.

## src/web/asset.zig

Asset fetch is asynchronous; poll `isReady()` before using the result.

## src/web/app.zig

Wasm entry points that call `std.log` must set `std_options.logFn` to
`zunk.web.logFn`: the default pulls in `std.Io.Threaded`, unavailable on
wasm32-freestanding. Browser log messages longer than 512 bytes are truncated.

## src/web/fx.zig

The host-services protocol is described in `docs/ARCHITECTURE.md` and
`src/gen/js/fx.js`. JavaScript copies request data before returning and queues
results until `poll`; it calls into wasm only during that poll. Caller-chosen
request IDs should be nonzero; unsolicited completions use zero. Completion
slices remain valid only until the next poll, which frees the previous batch.
JavaScript must refresh its memory view after allocating a record, since wasm
memory may grow. Delivery transfers ownership to the inbox.

Completion fields depend on kind: HTTP uses `a` for status (zero for transport
failure) and blobs for body and error; file-opened uses name, MIME, and bytes;
downloaded, storage-value, and query-value use `a` as a success or found flag;
clock uses `a` for UTC offset in minutes and an eight-byte little-endian Unix
millisecond value in its first blob. Dropped uses `a` for file/image/text,
`b` and `c` for image dimensions, `d` for thumbnail width, and blobs for name,
MIME, bytes, and thumbnail RGBA. Pasted-text uses its first blob for text.

The file picker waits for a user activation if none is active. Image clipboard
writing requires a secure context and user activation. An empty storage value
deletes the key. `encodeHeaders` skips empty or colon-containing names and
fields containing line breaks; its caller frees the returned buffer.

## src/gen/source_map.zig

Source maps cover bridge chunks at line granularity and embed their source;
generated lines outside these spans remain unmapped. Span ends are exclusive
and cannot precede their starts. Callers skip map generation when there are no
spans. A trailing partial line counts as a line.

## src/gen/serve.zig

The dev server expects bodyless GET requests to fit in the first read. The
WebSocket read loop assumes the dev client sends no data frames; watcher
threads broadcast while connection threads wait for closure, and the mutex
protects the slot list. HMR swaps only when enabled and only wasm changed;
other changes trigger a full reload. Normal peer disconnects are not logged.

## src/main.zig

Bridge dependencies are loaded in CLI order, followed by the first project
bridge found (`bridge.js`, then `js/bridge.js`) so the project can override
dependency symbols. A missing requested font stops the build to avoid silent
fallback. Deploy filenames hash JavaScript before the source-map trailer, but
SRI covers the final served bytes. The build fingerprint includes the zunk
executable as well as the project's inputs, so rebuilding the generator
invalidates its cache.
