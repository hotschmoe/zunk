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

## Phase 3 -- Developer Experience (DONE)

### 3.1 `zunk init` -- DONE

Scaffolds a new project with 4 files: `build.zig`, `build.zig.zon`, `src/main.zig` (minimal canvas hello-world), and `.gitignore`. Accepts an optional subdirectory name. Guards against re-initialization if `build.zig` already exists.

### 3.2 Diagnostic error overlay -- DONE (implemented in Phase 2)

Build errors are displayed in the browser via WebSocket. The server captures `zig build` stderr and broadcasts an `"error:"` message; the injected reload script renders it as a fixed overlay with red text on black background. Cleared automatically on successful rebuild.

### 3.3 Build caching -- DONE

Mtime-based fingerprinting of `src/*.zig`, `build.zig`, `build.zig.zon`, the WASM binary, and `bridge.js`. Fingerprint stored as 16-byte i128 in `{output_dir}/.zunk_cache`. Skips rebuild when fingerprint matches. `--force` flag bypasses cache. Applied to both `build` and `deploy` commands.

### 3.4 `zunk doctor` -- DONE

Checks zig version (spawns `zig version`, parses semver, validates >= 0.15.2), wasm32 target availability, project structure (`build.zig`, `build.zig.zon`, `src/main.zig`), and `.gitignore` presence. Color-coded output with OK/WARN/FAIL status per check and a summary line.

### 3.5 Resolution report improvements -- DONE

- Color-coded output: green for exact/high confidence, yellow for medium, red for stubs
- "Did you mean?" suggestions via Levenshtein edit distance (threshold <= 3) against the exact match database and prefix rules
- `--verbose` / `-v` flag shows all resolutions grouped by category with confidence tags
- `--report-json` flag emits machine-readable JSON (build fingerprint, resolutions array, category counts, lifecycle exports)

---

## Phase 4 -- WebGPU and Ecosystem

### 4.1 WebGPU bindings -- DONE

Full WebGPU bindings are implemented and working. The particle-life example uses them end-to-end with compute shaders and render pipelines.

**Done:**
- [x] Adapter and device acquisition (auto-init in generated JS when WebGPU imports detected)
- [x] Shader module creation from WGSL source -- `gpu_create_shader_module`
- [x] Buffer creation, data upload, and destruction -- `gpu_create_buffer`, `gpu_buffer_write`, `gpu_buffer_destroy`
- [x] Buffer-to-buffer copy in command encoder -- `gpu_copy_buffer_in_encoder`
- [x] Texture creation, view creation, and destruction -- `gpu_create_texture`, `gpu_create_texture_view`, `gpu_destroy_texture`
- [x] HDR texture support (`rgba16float` format) -- `gpu.createHDRTexture()`
- [x] Asset-to-texture loading (fetch image, decode, upload) -- `gpu_create_texture_from_asset`, `gpu_is_texture_ready`
- [x] Bind group layout and bind group creation (buffer + texture view entries) -- `gpu_create_bind_group_layout`, `gpu_create_bind_group`
- [x] Pipeline layout creation -- `gpu_create_pipeline_layout`
- [x] Compute pipeline creation -- `gpu_create_compute_pipeline`
- [x] Render pipeline creation (with alpha blending) -- `gpu_create_render_pipeline`
- [x] HDR render pipeline creation (configurable format + blend modes) -- `gpu_create_render_pipeline_hdr`
- [x] Command encoder creation and submission -- `gpu_create_command_encoder`, `gpu_encoder_finish`, `gpu_queue_submit`
- [x] Compute pass encoding (set pipeline, set bind group, dispatch, end) -- 5 functions
- [x] Render pass encoding (begin with clear color, set pipeline, set bind group, draw, end) -- 5 functions
- [x] HDR render pass (render to texture view) -- `gpu_begin_render_pass_hdr`
- [x] Present (flush command encoder to screen) -- `gpu_present`
- [x] DPR-aware resize handler for WebGPU canvas
- [x] Layer 2 ergonomic wrappers with typed handles in `web/gpu.zig` (33 extern fns, typed Device/Buffer/Texture/Pipeline aliases, convenience constructors)
- [x] ABI-matched struct layouts (`BindGroupLayoutEntry` = 40 bytes, `BindGroupEntry` = 32 bytes)
- [x] Texture format enum (rgba16float, rgba32float, bgra8unorm, rgba8unorm, rgba8unorm_srgb, depth24plus, depth32float)
- [x] Usage flag constants matching WebGPU spec (`BufferUsage`, `TextureUsage`, `ShaderVisibility`)

**Not yet implemented:**
- [ ] Sampler creation and sampling
- [ ] Vertex buffer layouts (vertex attributes, step mode)
- [ ] Render pipeline depth/stencil state
- [ ] Multiple color attachment targets
- [ ] Render bundles
- [ ] Timestamp queries / pipeline statistics
- [ ] Error handling (device lost, validation errors)

### 4.2 Expand the knowledge base -- PARTIALLY DONE

**Done:**
- [x] WebSocket API -- `ws_connect`, `ws_send`, `ws_close`, `ws_on_message`
- [x] Storage API -- `storage_set`, `storage_get`, `storage_remove`, `storage_clear`
- [x] Fetch API -- `fetch_get`, `fetch_get_response_ptr`, `fetch_get_response_len`
- [x] DOM manipulation -- `dom_set_text`, `dom_set_html`, `dom_set_attr`, `dom_query`, `dom_create_element`, `dom_append_child`, `dom_remove`, `dom_set_style`, `dom_add_class`, `dom_remove_class`
- [x] Pointer Lock -- `input_lock_pointer`, `input_unlock_pointer`
- [x] Fullscreen -- `ui_request_fullscreen`
- [x] HTML UI system -- panels, sliders, checkboxes, buttons, separators, status bar (full `web/ui.zig` + resolution support)

**Not yet implemented:**
- [ ] WebXR (VR/AR headset access)
- [ ] WebRTC (peer-to-peer communication)
- [ ] Web Workers (background threads)
- [ ] IndexedDB (structured storage)
- [ ] WebMIDI (musical instruments)
- [ ] Gamepad API (beyond current basic support -- gamepad section exists in InputState but JS flush skips it)

### 4.3 Library convention for bridge.js -- DONE

Zig packages ship a `bridge.js` at their package root. Consumers opt in via `zunk.installApp(..., .{ .bridge_deps = &.{ teak, ... } })`. Dep-provided chunks are merged in listed order; the consumer's own `bridge.js` (or `js/bridge.js`) is appended last so it can override. Each chunk is banner-commented with its origin. `--bridge-dep <path>` is the underlying repeatable CLI flag (installApp wires it up automatically).

### 4.4 Source maps

Generate source maps so developers can debug their Zig code in browser devtools. Map generated JS lines back to WASM function names, and ideally to Zig source locations via DWARF debug info in the WASM.

### 4.5 WASM size optimization

Integrate wasm-opt or implement custom optimization passes:
- Strip debug sections for release builds
- Remove unused function types
- Optimize memory layout

---

## Phase 4.5 -- Canvas-based Immediate-Mode UI (IN PROGRESS)

A WebGPU/Canvas2D immediate-mode UI system for building debug panels and tools, rendered entirely from WASM. Separate from the HTML-based `web/ui.zig` overlay system.

**Done:**
- [x] `web/imgui.zig` -- generic `Ui(Backend)` with comptime backend selection
- [x] `web/render_backend.zig` -- `Canvas2DBackend` implementation, backend validation, `Rect`/`Color` types
- [x] Theme system with configurable colors, sizes, fonts
- [x] Layout system (vertical/horizontal, nested up to 16 levels)

**Needs polish:**
- [ ] Widget coverage: verify slider, checkbox, button, text, separator all work end-to-end
- [ ] The imgui-demo example exists -- verify it runs correctly
- [ ] WebGPU render backend (for rendering UI on GPU canvas instead of Canvas2D overlay)

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
