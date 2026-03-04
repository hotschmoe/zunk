# zunk Roadmap

## Phase 1 -- Foundation (DONE)

The core architecture is implemented and functional.

- [x] WASM binary analyzer (import/export/type/name sections) -- `gen/wasm_analyze.zig`
- [x] 5-tier auto-resolution engine with Web API knowledge base -- `gen/js_resolve.zig`
- [x] JS + HTML code generator (adaptive, minimal output) -- `gen/js_gen.zig`
- [x] Binding system (Handle, CallbackFn, string exchange, comptime manifest) -- `bind/bind.zig`
- [x] Layer 2 web modules (canvas, input, audio, asset, app) -- `web/*.zig`
- [x] CLI with `build` command (reads .wasm, generates JS+HTML to dist/) -- `main.zig`

---

## Phase 2 -- Complete the Build Pipeline (DONE)

The CLI works end-to-end on pre-compiled WASM. One-command builds are achieved via `installApp()`.

### 2.1 Auto-compilation -- DONE (via installApp pattern)

**Done:**
- [x] `ServeConfig.build_cmd` field defined (defaults to `{ "zig", "build" }`) -- `gen/serve.zig`
- [x] `sourceWatcherThread` runs `zig build` as child process on file changes -- `gen/serve.zig`
- [x] All 5 example projects have working `build.zig` + `build.zig.zon`
- [x] `installApp()` helper in zunk's `build.zig` wires up the full pipeline as a build step
- [x] Compiler error capture and display in browser error overlay
- [x] Helpful error message when `--wasm` is missing, guiding users to `installApp()`

**Deferred to Phase 3 (nice-to-have):**
- [ ] Detect user project structure (look for `build.zig` or `src/main.zig`) in `buildCommand()`
- [ ] Initial auto-compilation: run `zig build` before WASM analysis instead of requiring `--wasm`
- [ ] If only `src/main.zig` exists (no `build.zig`), invoke zig directly with wasm32-freestanding target
- [ ] Locate the compiled `.wasm` output automatically (scan `zig-out/`)
- [ ] Pass the zunk runtime library as a module dependency so `@import("zunk")` works (for no-build.zig case)

### 2.2 End-to-end validation -- DONE (manual), NEEDS POLISH (automated)

**Priority: Critical**

**Done:**
- [x] 5 working examples: input-demo, imgui-demo, audio-demo-1, audio-demo-2, particle-life
- [x] All compile to WASM and produce correct JS+HTML output via `zunk build`
- [x] 0 stubs in resolution for all examples (full auto-resolution works)
- [x] Examples verified running in browser (manual testing)
- [x] CI runs `zig build` + `zig build test` across 3 platforms x 5 optimization levels

**Remaining:**
- [ ] Automated smoke test: compile an example and validate the generated JS is syntactically correct
- [ ] Consider headless browser validation (Playwright/Puppeteer) for CI -- nice-to-have, not blocking

### 2.3 Dev server -- DONE

**Done:**
- [x] HTTP server on localhost with configurable port (default 8080) -- `gen/serve.zig`
- [x] Correct MIME types: html, js, wasm, css, json, png, svg, ico, woff2, mp3, ogg, wav, wgsl
- [x] URL printed to stdout with rich formatted banner
- [x] SPA fallback (routes without extensions serve index.html)
- [x] Embedded favicon fallback
- [x] Directory traversal protection
- [x] COOP/COEP headers for SharedArrayBuffer support
- [x] HTTP proxy support (`--proxy prefix=url`)
- [x] Platform-specific socket I/O (Windows + POSIX)

### 2.4 File watcher + live reload -- DONE

**Done:**
- [x] Watch `src/` and `build.zig*` for changes via mtime-based fingerprinting (500ms polling)
- [x] Watch `dist/` for output changes separately
- [x] Debounce: 500ms polling interval + 100ms post-change delay before rebuild
- [x] WebSocket server on `/__zunk_ws` endpoint with client registry
- [x] Reload script auto-injected into HTML responses by the server (not baked into GenOptions)
- [x] Build error overlay displayed in browser on compile failure
- [x] `--no-watch` flag to disable source watching

### 2.5 bridge.js auto-discovery and merging -- DONE

**Done:**
- [x] `GenOptions.bridge_js` field exists -- `gen/js_gen.zig`
- [x] Merging: if bridge_js is provided, it is inserted into generated JS output
- [x] Build report suggests `bridge.js` or `js/bridge.js` paths when stubs are present
- [x] Auto-discover `bridge.js` or `js/bridge.js` from user project root in `buildCommand()`

**Deferred to Phase 4.3:**
- [ ] Scan Zig package dependencies for `bridge.js` files
- [ ] Document the format: bridge.js should export an object whose keys become env imports

### 2.6 `zunk deploy` -- DONE

**Done:**
- [x] XxHash3 fingerprint computed for generated JS (used in build report header and deploy filenames)
- [x] Asset copying from `src/assets/` to `dist/assets/` exists
- [x] `deploy` command added to CLI dispatcher in `main.zig`
- [x] Content-hashed .js and .wasm filenames (e.g., `app-a1b2c3d4.js`)
- [x] Subresource integrity (SHA-384) on script tag
- [x] Preload hint for .wasm file
- [x] Output a clean `dist/` directory ready for any static file server

**Deferred (nice-to-have):**
- [ ] Copy assets with hashed filenames + manifest
- [ ] Strip debug info from WASM (`-Doptimize=ReleaseSmall` or wasm-opt)

---

## Phase 3 -- Developer Experience

### 3.1 `zunk init`

Scaffold a new project: create `src/main.zig` with a minimal example, `build.zig` if needed, and a `.gitignore`.

### 3.2 Diagnostic error overlay -- DONE (implemented in Phase 2)

Build errors are displayed in the browser via WebSocket. The server captures `zig build` stderr and broadcasts an `"error:"` message; the injected reload script renders it as a fixed overlay with red text on black background. Cleared automatically on successful rebuild.

### 3.3 Build caching

Skip recompilation if source files haven't changed. Compare mtimes or content hashes of `src/` against the last build timestamp.

### 3.4 `zunk doctor`

Diagnose common issues: check zig version meets minimum, verify wasm32-freestanding target is available, check for common misconfigurations.

### 3.5 Resolution report improvements

The build report currently prints to stderr. Improvements:
- Color-coded output (green for exact, yellow for high, red for stubs)
- Suggestion text for each stub ("did you mean `canvas_fill_rect`?")
- Optional `--verbose` flag showing all resolutions, not just stubs
- Machine-readable output format (JSON) for tooling integration

---

## Phase 4 -- WebGPU and Ecosystem

### 4.1 WebGPU bindings

The resolution engine has `zunk_gpu_*` prefix rules but the generator functions are stubs. Real WebGPU operations (adapter/device request, pipeline creation, buffer management, render pass encoding) need substantial JS implementations.

Requirements:
- Adapter and device acquisition
- Shader module creation from WGSL source
- Buffer creation and data upload
- Render pipeline creation
- Render pass encoding and submission
- Texture and sampler management
- Compute pipeline support

### 4.2 Expand the knowledge base

Add resolution rules for more Web APIs:
- WebXR (VR/AR headset access)
- WebRTC (peer-to-peer communication)
- Web Workers (background threads)
- IndexedDB (structured storage)
- WebMIDI (musical instruments)
- Gamepad API (beyond current basic support)
- Pointer Lock API (FPS-style mouse capture)
- Fullscreen API

### 4.3 Library convention for bridge.js

Define and document the convention for Zig packages that ship browser-side JS. When a zunk user depends on a Zig package that includes a `bridge.js`, zunk should automatically discover and merge it.

### 4.4 Source maps

Generate source maps so developers can debug their Zig code in browser devtools. Map generated JS lines back to WASM function names, and ideally to Zig source locations via DWARF debug info in the WASM.

### 4.5 WASM size optimization

Integrate wasm-opt or implement custom optimization passes:
- Strip debug sections for release builds
- Remove unused function types
- Optimize memory layout

---

## Phase 5 -- Advanced Features

### 5.1 Hot module replacement (HMR)

Instead of full page reload on changes, swap the WASM module in place. Requires:
- Preserving JS-side state (handle table, audio context) across reloads
- Re-calling `init` on the new module
- Careful handling of WASM memory (old memory must be discarded)

### 5.2 Multi-page app support

Generate multiple HTML pages from a single project, each with its own WASM entry point. Useful for apps with distinct views (editor, preview, settings).

### 5.3 Proxy support for API backends -- DONE (implemented in Phase 2)

The dev server supports `--proxy prefix=url` to forward matching requests to a backend server. Implemented in `gen/serve.zig`.

### 5.4 Asset pipeline

The foundation is in place: `zunk.web.asset` provides generic URL-based
fetching, and the build tool copies `src/assets/` to `dist/assets/`.

Remaining work beyond the current simple file copying:
- Content-hashed filenames for cache busting
- Manifest file for asset URL lookups from WASM
- Batch loading (`asset.fetchAll`)
- Progress tracking (`asset.getProgress`)
- CSS minification
- Image optimization
- Font subsetting

### 5.5 `Zunk.toml` configuration

Optional configuration file for projects that need to customize behavior:
- Canvas size and mode (fixed vs fullscreen)
- Custom HTML template overrides
- Asset directories
- Dev server port
- Optimization level
- Custom meta tags and page title
