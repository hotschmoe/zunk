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

## Phase 2 -- Complete the Build Pipeline

The CLI works end-to-end on pre-compiled WASM. These items close the gap to "one command."

### 2.1 Auto-compilation

**Priority: Critical**

The CLI currently requires `--wasm <path>` pointing to a pre-compiled binary. It should invoke `zig build` (or `zig build-exe -target wasm32-freestanding`) to compile the user's Zig source to WASM automatically.

Requirements:
- Detect user project structure (look for `src/main.zig` or `build.zig`)
- If `build.zig` exists, run `zig build` with appropriate target
- If only `src/main.zig` exists, invoke zig directly with wasm32-freestanding target
- Pass the zunk runtime library as a module dependency so `@import("zunk")` works
- Capture and display compiler errors cleanly

### 2.2 End-to-end validation

**Priority: Critical**

No example currently proves the full pipeline works. Need to compile a real Zig WASM project through the analyzer and verify the generated JS runs correctly in a browser.

Requirements:
- Get `examples/bouncing-balls/` (or a simpler hello-world) compiling to WASM
- Run it through `zunk build`
- Open the generated output in a browser and confirm it works
- This becomes the smoke test for all future changes

### 2.3 Dev server

**Priority: High**

`zunk run` should compile, generate, and serve -- then keep running and watch for changes.

Requirements:
- HTTP server using `std.net` that serves `dist/` on localhost
- Correct MIME types for .html, .js, .wasm, .css, images
- Print the URL to stdout

### 2.4 File watcher + live reload

**Priority: Medium**

Rebuild on source changes and refresh the browser.

Requirements:
- Watch `src/` for .zig file changes
- Debounce rebuilds (avoid thrashing on rapid saves)
- Inject a small WebSocket/SSE client into the generated HTML that triggers page reload
- The `autoreload` plumbing in `GenOptions` already exists, just needs wiring

### 2.5 bridge.js auto-discovery and merging

**Priority: Medium**

The escape hatch for APIs zunk doesn't support natively.

Requirements:
- Look for `bridge.js` or `js/bridge.js` in the user project root
- Look for `bridge.js` in Zig package dependencies
- Merge discovered JS into the generated output (the `bridge_js` field in GenOptions exists)
- Document the format: bridge.js should export an object whose keys become env imports

### 2.6 `zunk deploy`

**Priority: Medium**

Production build with content-hashed filenames and optimized output.

Requirements:
- Content-hash .js and .wasm filenames (e.g., `app-a1b2c3.js`)
- Subresource integrity attributes on script/link tags
- Preload hints for the .wasm file
- Copy assets/ to dist/ with hashed filenames
- Strip debug info from WASM (`-Doptimize=ReleaseSmall` or wasm-opt)
- Output a clean `dist/` directory ready for any static file server

---

## Phase 3 -- Developer Experience

### 3.1 `zunk init`

Scaffold a new project: create `src/main.zig` with a minimal example, `build.zig` if needed, and a `.gitignore`.

### 3.2 Diagnostic error overlay

When a build fails, show the error in the browser instead of a blank page. Inject an error overlay HTML/CSS into the served page that displays compiler output.

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

### 5.3 Proxy support for API backends

During development, proxy certain URL patterns to a backend server. Useful for apps that need a real API during dev without CORS issues.

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
