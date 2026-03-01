# How To Handle Assets

A living document. We revisit this as the project evolves.

---

## Context (Feb 2027)

zunk generates all HTML and JS from WASM analysis. The developer writes only Zig.
Today, assets (audio, images, data files) are embedded into the WASM binary at
compile time via Zig's `@embedFile`. This works well for small assets but becomes
a problem as apps grow: large textures, music tracks, and data files bloat the
WASM binary and increase initial load time.

We need a path for assets that live *outside* the WASM binary -- fetched by the
browser at runtime and cached normally by HTTP infrastructure.

### What already exists

- `audio.zig` already declares `audio.load(url)` backed by extern `zunk_audio_load`
- `js_resolve.zig` already resolves `audio_load` to a `fetch(url) -> decodeAudioData` JS body
- The dev server (`serve.zig`) serves files from `dist/` with correct MIME types
- The build system does NOT currently copy `src/assets/` to `dist/`
- There is no generic asset/fetch-from-URL abstraction in the Zig layer

### The question

How should zunk handle external (non-embedded) assets across the full pipeline:
Zig API, JS generation, build system, dev server, and production deployment?

---

## Option A: Audio-specific `loadFromUrl`

The simplest path. Audio already has the extern wired up. We just need to make
it work end-to-end.

### Zig API

```zig
// Already exists in audio.zig:
sfx_buffer = audio.load("assets/explode.ogg");

// Polling works identically to loadFromMemory:
if (audio.isReady(sfx_buffer)) { ... }
```

### JS generation

Already done. The resolver emits:
```js
const url = readStr(arguments[0], arguments[1]);
const h = H.nextId();
fetch(url).then(r=>r.arrayBuffer())
  .then(b=>H.get(zunkAudioCtx).decodeAudioData(b))
  .then(buf=>{H.set(h,buf);});
return h;
```

### Build changes needed

- Copy `src/assets/` to `dist/assets/` during build
- Dev server already serves `dist/` so no server changes needed

### Evaluation

**1. Zig idiomaticness: GOOD**

This follows the Zig pattern of "do the simplest thing that works." No new
abstractions, no new modules. The function already exists. Using a string
literal for the URL is natural in Zig -- it is a comptime-known `[]const u8`,
no allocator needed. The polling pattern (`load` then `isReady`) mirrors
`loadFromMemory` exactly, so there is zero new API surface to learn.

The downside: the URL is a runtime string from Zig's perspective. The build
system cannot introspect which URLs the app will request without parsing WASM
data sections or debug info. This means the build system cannot do things like
content-hash the filename or warn about missing assets at build time.

**2. Developer friction: LOW (rating: 9/10)**

For audio, this is essentially zero friction -- the API exists, the developer
just calls `audio.load("assets/foo.ogg")` instead of
`audio.loadFromMemory(@embedFile("assets/foo.ogg"))`. Same polling pattern,
same handle type, same everything.

But this only covers audio. When the developer wants to load an image, a JSON
file, or a binary blob from a URL, they need... a different API for each? Or
they need Option B. So Option A is low friction *for audio* but does not
generalize.

**3. Performance and compatibility: EXCELLENT (rating: 9/10)**

- Browser: `fetch()` is universally supported. The browser handles caching via
  standard HTTP cache headers (Cache-Control, ETag, etc.). Audio decoding via
  `decodeAudioData` is the standard path. No exotic APIs.
- Server: Any static file server (nginx, S3, Cloudflare Pages) serves the
  `dist/` directory as-is. Assets are just files next to the WASM. nginx needs
  zero special configuration. The MIME types are standard.
- Performance: Assets load in parallel with (or after) WASM. The browser can
  cache them independently of the WASM binary. Smaller WASM means faster
  `instantiateStreaming`. The downside: two round trips instead of one (WASM
  then asset fetch). For audio this rarely matters since the user must interact
  before AudioContext starts anyway.

**4. Future extensibility: LIMITED (rating: 4/10)**

This is audio-only. Every new asset type (images, fonts, data files, spritesheets)
would need its own `loadFromUrl` variant. No shared progress tracking, no shared
caching strategy, no unified asset manifest. If we later want "show a loading
screen while assets download," each module would need its own progress reporting.

---

## Option B: Generic asset module (`zunk.web.asset`)

A new module that handles fetching any asset type, with type-specific decoders
layered on top.

### Zig API (proposed)

```zig
const asset = zunk.web.asset;

// Fetch raw bytes from a URL. Returns a handle immediately.
const explode_handle = asset.fetch("assets/explode.ogg");

// Check loading state (works for any asset type)
if (asset.isReady(explode_handle)) {
    // Decode as audio -- passes the raw ArrayBuffer to decodeAudioData
    sfx_buffer = audio.decodeAsset(explode_handle);
}

// Could also work for other types:
// const img = image.decodeAsset(sprite_handle);
// const bytes = asset.getBytes(data_handle);
```

Alternative: single-step convenience that combines fetch + decode:

```zig
sfx_buffer = audio.load("assets/explode.ogg");   // fetch + decode, same as Option A
const raw = asset.fetchBytes("assets/data.bin");  // fetch only, get raw bytes
```

### JS generation

New resolver category `asset` with externs:

```
zunk_asset_fetch(url_ptr, url_len) -> handle      // fetch() -> store ArrayBuffer
zunk_asset_is_ready(handle) -> i32                 // check if fetch completed
zunk_asset_get_ptr(handle) -> i32                  // copy bytes to WASM memory
zunk_asset_get_len(handle) -> i32                  // get byte length
```

JS implementation:
```js
zunk_asset_fetch() {
  const url = readStr(arguments[0], arguments[1]);
  const h = H.nextId();
  fetch(url).then(r => r.arrayBuffer()).then(buf => { H.set(h, buf); });
  return h;
}
```

Audio, image, and other type-specific decoders call into the asset handle to
get the raw bytes, then process them with their domain-specific API.

### Build changes needed

Same as Option A: copy `src/assets/` to `dist/assets/`.

### Evaluation

**1. Zig idiomaticness: GOOD (with caveats)**

The separation of "fetch" from "decode" is very Zig -- it mirrors how Zig
separates allocation from initialization, and how `std.io` separates reading
from parsing. The handle-based async pattern is consistent with how audio
already works.

The caveat: this introduces a new module (`web.asset`) and a two-step pattern
(fetch then decode) that is more complex than the single-call `audio.load()`.
Zig favors explicitness, which this delivers, but it also favors simplicity,
which this slightly sacrifices.

The `asset.fetch` returning an opaque handle to raw bytes is analogous to
`std.fs.openFile` returning a File handle -- you get the resource, then
decide what to do with it. This is idiomatic.

**2. Developer friction: MODERATE (rating: 6/10)**

Two steps where Option A has one. The developer must understand the asset
handle concept, the ready-check pattern, and the type-specific decoder step.
For audio specifically, this is strictly more work than `audio.load(url)`.

However, for developers loading *multiple* asset types, this is less friction
overall because there is one pattern to learn. "Fetch a handle, check ready,
decode" works for audio, images, JSON, binary data, etc.

The convenience wrappers (`audio.load(url)`) can sit on top, giving
developers a choice: simple single-call or explicit two-step.

**3. Performance and compatibility: EXCELLENT (rating: 9/10)**

Same `fetch()` under the hood as Option A. Same HTTP caching story.

Additional performance consideration: with a generic asset module, we could
batch-start multiple fetches at init time and show unified loading progress.
The browser can parallelize these fetches (HTTP/2 multiplexing helps). This
is harder to coordinate with per-module `loadFromUrl` calls.

The raw ArrayBuffer approach means zero-copy for binary data -- the bytes go
straight from `fetch()` into WASM memory via the existing `(ptr, len)` pattern.
No unnecessary re-encoding.

**4. Future extensibility: VERY GOOD (rating: 8/10)**

This is the clear winner for extensibility:

- New asset types just need a decoder function, not new fetch plumbing
- Progress tracking: `asset.getProgress(handle) -> f32` works for everything
- Loading screens: check `asset.allReady(&handles)` in your frame loop
- Batch loading: `asset.fetchAll(&urls)` could be added later
- Streaming: large assets could use ReadableStream under the hood
- Cache control: could add `asset.fetchWithOptions(url, .{ .cache = .reload })`

The risk: over-engineering. If zunk apps end up only loading audio and maybe
a few images, the generic module is unnecessary abstraction. YAGNI applies.

---

## Option C: Asset manifest via build.zig

Assets declared in the build file, not in Zig source. The build system knows
about all assets upfront and can optimize accordingly.

### Zig API (proposed)

```zig
// build.zig
zunk.installApp(b, zunk_dep, exe, .{
    .assets = &.{
        .{ .path = "src/assets/explode.ogg", .name = "explode" },
        .{ .path = "src/assets/sprite.png", .name = "sprite" },
    },
});
```

The build step generates a Zig module (or comptime data) that the app imports:

```zig
// In app code -- assets are known at comptime
const assets = @import("zunk").assets;  // auto-generated from build.zig

export fn init() void {
    // Name is comptime-checked -- typo = compile error
    sfx_buffer = audio.load(assets.explode);
    // assets.explode resolves to the URL string "assets/explode-a3f2b1c8.ogg"
}
```

### JS generation

The build system generates a manifest that maps asset names to hashed filenames.
The JS codegen can embed this manifest or use it to emit preload hints:

```html
<link rel="preload" href="assets/explode-a3f2b1c8.ogg" as="fetch">
```

### Build changes needed

- New build step: process asset list, copy to `dist/assets/` with content hashes
- Generate a Zig source file (or use build options) to expose asset paths to the app
- Optionally emit `<link rel="preload">` tags in generated HTML

### Evaluation

**1. Zig idiomaticness: MIXED (rating: 5/10)**

On one hand, Zig's build system is powerful and meant to handle this kind of
thing. `build.zig` is the natural place to declare "what goes into the build."
Comptime-checked asset names preventing typos is very Zig.

On the other hand, this splits asset concerns across two files: `build.zig`
declares what assets exist, `main.zig` uses them. In Zig, you typically import
what you need where you need it. Having `@embedFile` right next to the code
that uses the data is more idiomatic than indirecting through the build system.

The code generation aspect (generating a Zig module from build.zig data) is
precedented -- Zig's build system does this for version strings and build
options. But generating asset path mappings feels like it is trying to be a
bundler, which is not what Zig's build system was designed for.

**2. Developer friction: HIGH (rating: 4/10)**

- Two places to update when adding an asset (build.zig + source)
- Must understand the build-time asset processing pipeline
- Content hashing adds complexity to the mental model
- If the developer just wants to load a sound file, they have to touch build.zig
- Forgetting to add an asset to build.zig means a runtime 404, not a compile error
  (unless we generate a module, which adds more build complexity)

The upside of compile-time checking (typo = error) partially offsets this, but
only if we go the full route of generating a Zig module.

**3. Performance and compatibility: BEST (rating: 10/10)**

This is where Option C shines:

- **Content hashing**: `explode-a3f2b1c8.ogg` means infinite cache lifetime.
  nginx can serve with `Cache-Control: immutable, max-age=31536000`. No cache
  busting problems. No stale assets after deploys.
- **Preload hints**: The HTML generator knows all assets upfront, so it can emit
  `<link rel="preload">` tags. The browser starts fetching assets before JS
  even executes. This is the fastest possible loading strategy.
- **CDN-friendly**: Hashed filenames work perfectly with CDN edge caching.
- **Build-time validation**: Missing files caught at build time, not runtime.
- **Selective inclusion**: Only declared assets are copied, so no accidental
  deployment of unused files.

For production deployment behind nginx/Cloudflare/S3, this is the gold standard.
Every serious web framework (Vite, Webpack, Next.js) does content hashing for
exactly these reasons.

**4. Future extensibility: GOOD (rating: 7/10)**

The manifest opens doors:

- Asset compression (build step can pre-compress with gzip/brotli)
- Spritesheet generation (combine multiple images at build time)
- Asset size budgets (fail build if total assets exceed threshold)
- Integrity hashes (SRI for `<script>` and `<link>` tags)

But the manifest is static -- it cannot handle dynamically determined assets
(e.g., loading a user-selected file, or procedurally choosing which level
data to fetch). Those still need a runtime fetch mechanism.

The build.zig coupling also means third-party zunk libraries cannot easily
declare their own assets. The app's build.zig must explicitly list everything.

---

## Option D: Convention-based auto-serve (`src/assets/` -> `dist/assets/`)

The zero-configuration approach. Drop a file in `src/assets/`, reference it
by path, it just works.

### Zig API

No new API. Use existing `audio.load("assets/explode.ogg")` or a future
generic `asset.fetch("assets/sprite.png")`.

### Build changes needed

- Build step: recursively copy `src/assets/**` to `dist/assets/`
- Dev server: already serves from `dist/`, so no changes needed

### How it works

```
src/
  main.zig
  assets/
    explode.ogg      <-- developer drops file here
    sprite.png

     | build step copies |
     v                   v

dist/
  index.html
  app.js
  app.wasm
  assets/
    explode.ogg      <-- served at /assets/explode.ogg
    sprite.png
```

### Evaluation

**1. Zig idiomaticness: NEUTRAL (rating: 6/10)**

This is not really a Zig pattern -- it is a web framework convention (Rails
`public/`, Next.js `public/`, Vite `public/`). Zig does not have opinions
about asset directories.

That said, it does not *conflict* with Zig idioms either. The Zig code just
uses string URLs, which is fine. And convention-over-configuration is a valid
design choice for a tool that aims to eliminate boilerplate.

The concern: the build system silently copies files with no Zig-visible
declaration. If `src/assets/explode.ogg` does not exist, the developer gets
a runtime 404 in the browser, not a compile error. This is un-Zig-like.

**2. Developer friction: LOWEST (rating: 10/10)**

Drop a file. Reference it. Done.

No build.zig changes. No manifest. No new imports. No configuration.
This is the simplest possible developer experience for "I have a file
and I want the browser to be able to load it."

This is what developers from other ecosystems expect. "Put it in the
assets folder" is universally understood.

**3. Performance and compatibility: GOOD (rating: 7/10)**

- Browser: Standard `fetch()`, standard HTTP caching. Works everywhere.
- Server: Files are just files in a directory. nginx, S3, anything works.
- Performance: Assets load after WASM, no preload hints unless we add them.

The gap vs Option C:

- **No content hashing**: `explode.ogg` never changes its name, so cache
  invalidation depends on ETags, Last-Modified, or the developer manually
  renaming files. After a deploy, users might get stale cached assets.
- **No preload hints**: The build system does not know which assets the app
  uses (URLs are runtime strings), so it cannot emit `<link rel="preload">`.
- **No build-time validation**: Typo in the URL string = runtime 404.
- **Copies everything**: Unused files in `src/assets/` get deployed too.

For dev mode, none of these matter. For production, the caching gap is real
but mitigable (the dev server already sets `Cache-Control: no-store`; a
production deploy could add a build fingerprint query parameter).

**4. Future extensibility: MODERATE (rating: 6/10)**

Can be enhanced incrementally:

- Add content hashing later (copy as `explode-[hash].ogg`, rewrite URLs)
- Add a simple manifest (scan `dist/assets/`, emit JSON)
- Add preload hints (scan WASM data section for URL-like strings)

But each enhancement takes this closer to Option C. If we end up needing
content hashing, preloading, and build validation, we have reinvented
Option C the hard way.

---

## Comparison Matrix

```
                     | A: audio-url | B: generic  | C: manifest  | D: convention |
---------------------+--------------+-------------+--------------+---------------+
Zig idiomatic        |    Good      |    Good     |    Mixed     |   Neutral     |
Developer friction   |    9/10      |    6/10     |    4/10      |   10/10       |
Perf/compatibility   |    9/10      |    9/10     |   10/10      |    7/10       |
Future extensibility |    4/10      |    8/10     |    7/10      |    6/10       |
Implementation cost  |    Tiny      |   Medium    |    Large     |    Small      |
Already partly built |    YES       |    No       |    No        |    No         |
---------------------+--------------+-------------+--------------+---------------+
```

---

## Open Questions

1. **How big will zunk apps realistically get?** If most apps are small demos
   and games (< 5MB total assets), Option A+D is probably fine forever. If we
   expect apps with 50MB+ of assets, Option B or C becomes more important.

2. **Do we want build-time asset validation?** The ability to catch "file not
   found" at build time rather than runtime is valuable. Option C gives this
   for free. Options A/D do not. Option B does not inherently, but could be
   extended.

3. **Content hashing -- do we care now?** For dev mode, no. For production
   deploys, content hashing is the industry standard for cache correctness.
   If we skip it now, we should design the system so it can be added later
   without breaking changes.

4. **Should `@embedFile` remain the primary path?** Embedding is simpler,
   requires zero infrastructure, and works offline. Maybe external assets
   should be the *alternative* path, not the default. The naming of the
   demos ("bundled" vs "cached") suggests we think of them as parallel
   strategies, not old-vs-new.

5. **What about streaming/progressive loading?** For large assets (music
   tracks, video), `fetch()` loads the entire file before the app can use
   it. Streaming via `ReadableStream` or `MediaSource` could enable
   progressive playback. This is a future concern but affects API design.

---

## Decision Log

| Date       | Decision | Rationale |
|------------|----------|-----------|
| 2027-02-27 | Created document, evaluating options A-D | Need external asset path for audio-demo-2-assets-cached |
| 2027-02-27 | **Go straight to Option B** (generic asset module) + Option D (convention-based serving) | See reasoning below |
| 2027-02-27 | **Option B + D implemented** | See implementation notes below |

### Why Option B (2027-02-27)

We considered starting with Option A (audio-only `loadFromUrl`) since the
audio extern and JS resolver already exist. But when we imagined real use
cases -- a game with dozens of sprites, sounds, and level data, or a
browser-based video editor loading user files -- Option A's per-module
approach falls apart immediately.

The deciding factor: **the cost delta between A and B is small, but the
capability delta is large.**

Minimal B is:
- One new file: `src/web/asset.zig` (~50 lines)
- Four new externs in the resolver
- `audio.load(url)` becomes sugar over `asset.fetch` + `audio.decodeAsset`

What minimal B gives us that A does not:
- One fetch pattern for all asset types (audio, images, data, binary blobs)
- Unified ready-checking: `asset.allReady(&handles)` for loading screens
- A foundation for progress tracking, batch loading, streaming -- all addable
  without API changes

What minimal B deliberately does NOT include yet (add when needed):
- Progress tracking (`asset.getProgress(handle) -> f32`)
- Streaming / progressive loading (`ReadableStream` under the hood)
- Batch loading (`asset.fetchAll(&urls)`)
- Custom cache strategies beyond the browser's default HTTP caching
- Content hashing (borrow from Option C when production deploys matter)

We pair B with Option D's convention: `src/assets/` auto-copies to
`dist/assets/`. Drop a file in, reference it by URL, done. Zero config.

---

## Implementation Notes (2027-02-27)

Option B + D is implemented. Here is what shipped and how the pieces connect.

### Files added/changed

| File | Change |
|------|--------|
| `src/web/asset.zig` | New module. Four externs, four public functions. |
| `src/root.zig` | Added `pub const asset` to the `web` struct. |
| `src/gen/js_resolve.zig` | New `.asset` category, `genAsset` resolver, `decode_asset` in audio resolver. |
| `src/web/audio.zig` | Added `decodeAsset(asset_handle)` for the fetch-then-decode workflow. |
| `src/main.zig` | Added `copyAssets()` -- copies `src/assets/` to `dist/assets/` during build. |
| `examples/audio-demo-2-assets-cached/src/main.zig` | Uses the new API end-to-end. |

### Zig API surface

```zig
const asset = zunk.web.asset;

// Fetch any asset by URL. Returns a handle immediately.
const h = asset.fetch("assets/explode.ogg");

// Poll for completion.
if (asset.isReady(h)) { ... }

// Get raw bytes (for binary data, JSON, etc.).
const len = asset.getLen(h);
const bytes = asset.getBytes(h, buffer[0..len]);

// Decode as audio (two-stage: fetch raw, then decode).
const audio_buf = audio.decodeAsset(h);
if (audio.isReady(audio_buf)) { audio.play(audio_buf); }
```

### JS resolver mappings

| Extern | JS body (abbreviated) |
|--------|-----------------------|
| `zunk_asset_fetch` | `fetch(url).then(r=>r.arrayBuffer()).then(buf=>{H.set(h,buf)})` |
| `zunk_asset_is_ready` | `H.get(h) instanceof ArrayBuffer ? 1 : 0` |
| `zunk_asset_get_len` | `b.byteLength` |
| `zunk_asset_get_ptr` | Copy ArrayBuffer into WASM linear memory |
| `zunk_audio_decode_asset` | `decodeAudioData(buf.slice())` via the audio context |

### Convention-based serving (Option D)

The build command (`buildCommand` in `main.zig`) calls `copyAssets()` after
writing the generated files. It walks `src/assets/` recursively and copies
every file to `{output_dir}/assets/`, preserving directory structure.

The dev server already serves `dist/` with correct MIME types, so assets
are immediately available at their relative URLs (e.g., `assets/explode.ogg`).

### Two-stage loading pattern

The key design choice: asset fetching is separated from type-specific decoding.

```
asset.fetch(url)          -- generic: fetch raw bytes from any URL
    |
    v
asset.isReady(handle)     -- generic: poll for completion
    |
    v
audio.decodeAsset(handle) -- type-specific: ArrayBuffer -> AudioBuffer
    |
    v
audio.isReady(buffer)     -- type-specific: poll for decode completion
```

This pattern extends naturally to other asset types (images, fonts, data files)
without changing the fetch infrastructure.

### What is NOT yet implemented

These are scaffolded as TODO comments in `src/web/asset.zig`:

- `fetchAll(urls) -> []Handle` -- batch loading
- `getProgress(handle) -> f32` -- download progress (0.0 to 1.0)
- `fetchStreaming(url) -> StreamHandle` -- progressive/streaming loading
- `fetchWithOptions(url, .{ .cache = .reload })` -- cache control
