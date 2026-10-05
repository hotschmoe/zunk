# zunk Architecture

## The Problem

When building web apps in Zig compiled to WASM, you face the **paired-file problem**: every browser API you want to call requires writing both a `.zig` file (with `extern fn` declarations) AND a `.js` file (with the actual browser API calls). These must be kept in sync -- matching function names, parameter counts, types, and calling conventions.

Rust solved this with `wasm-bindgen` -- a post-processing tool that reads proc macro annotations from the WASM binary and generates JavaScript glue. But wasm-bindgen exists because Rust *cannot* introspect types at compile time. The generated JS is massive (~50KB for hello-world), and developers must run it as a separate build step.

Zig has `comptime`. The binding definition IS the implementation. No post-processing needed.

## High-Level Pipeline

```
Developer's Zig Source
        |
        | zig build (target: wasm32-freestanding)
        v
   .wasm binary
        |
        | wasm_analyze.analyze()
        | Reads: import section, export section, type section,
        |        name section (debug), custom sections
        v
   Analysis { imports, exports, func_types, manifest }
        |
        | js_resolve.resolve() -- per import
        | 5-tier resolution: exact -> prefix -> signature -> param names -> stub
        v
   Resolution[] { js_body, confidence, category, feature requirements }
        |
        | js_gen.generate()
        | Determines which helpers to emit based on feature requirements
        v
   GenResult { js, html, report }
        |
        v
   dist/
     index.html    (generated)
     app.js        (generated)
     app.wasm      (compiled)
```

## Source Layout

```
src/
  root.zig                  Public API -- the "zunk" module users import
  main.zig                  CLI entry point (build/run/deploy/init/doctor/help/version)
  bind/
    bind.zig                FFI descriptor system, Handle, string exchange, callbacks
  web/
    canvas.zig              Canvas 2D API wrappers (27 extern fns)
    input.zig               Keyboard/mouse/touch/gamepad polling (shared memory)
    audio.zig               Web Audio API wrappers
    asset.zig               Generic URL-based asset loading
    app.zig                 Lifecycle utilities, logging, clipboard
    gpu.zig                 WebGPU bindings (50 extern fns, typed handles, descriptors)
    ui.zig                  HTML overlay UI (panels, sliders, checkboxes, buttons)
    imgui.zig               Immediate-mode canvas UI (comptime generic backend)
    render_backend.zig      Render backend abstraction (Canvas2DBackend)
  gen/
    wasm_analyze.zig        WASM binary parser
    js_resolve.zig          5-tier auto-resolution engine
    js_gen.zig              JS + HTML code generator
    serve.zig               Dev server, file watcher, live reload, WebSocket
```

There are two distinct halves: the **runtime library** (bind/, web/) that user code imports and compiles into WASM, and the **build tool** (gen/, main.zig) that runs natively and processes the resulting WASM binary.

## Module Details

### root.zig -- The Public API

The single entry point for user code: `@import("zunk")`.

Re-exports everything a developer needs:
- `zunk.bind` -- low-level FFI primitives
- `zunk.web.canvas`, `.input`, `.audio`, `.asset`, `.app` -- ergonomic wrappers
- `zunk.Handle`, `zunk.CallbackFn` -- convenience aliases
- `zunk.gen.*` -- build tool modules (for the CLI, not user code)

Uses `comptime` force-exports to ensure critical symbols appear in the WASM binary:
- `__zunk_string_buf_ptr` / `__zunk_string_buf_len` -- string exchange buffer
- `__zunk_invoke_callback` -- callback dispatch entry point

### bind/bind.zig -- FFI Descriptor System

The foundation layer. Defines how values cross the WASM<->JS boundary.

**ValKind** -- Enumeration of all value types:
```
i32, i64, f32, f64, bool    -- scalar (1 WASM param each)
handle                       -- opaque JS object reference (1 WASM param: i32 ID)
string, bytes, struct_val    -- compound (2 WASM params: ptr + len)
void                         -- no params
enum_val                     -- enum discriminant (1 WASM param)
```

**FuncDesc** -- Complete description of a function crossing the boundary:
- `name` -- function name (becomes part of the WASM import name)
- `module` -- namespace (e.g., "canvas", "audio")
- `params` -- array of ValDesc (name + kind + optional flag)
- `ret` -- return value descriptor
- `js_hint` -- generation hint (builtin, dom, webgpu, audio, etc.)
- `is_callback` -- whether this is a callback registration

**Handle** -- Opaque reference to a JS object:
```
Handle = enum(i32) { null_handle = 0, _ }
```
JS maintains a `Map<number, any>` handle table. Creating a JS object returns an integer ID. Zig stores it as Handle and passes it back when calling methods.

**String Exchange Buffer** -- 64KB shared region for JS->Zig string transfer:
```
Zig -> JS: pass pointer + length into WASM linear memory, JS reads via TextDecoder
JS -> Zig: JS writes to exchange buffer, returns length; Zig reads via readExchangeString()
```

**Callback Table** -- Up to 256 registered callbacks:
```
registerCallback(fn_ptr) -> id
JS calls __zunk_invoke_callback(id, a0, a1, a2, a3) -> dispatches to Zig fn
```

**Manifest Serialization** -- Comptime function that encodes an array of FuncDesc into a compact binary format. This gets embedded as a WASM custom section named "zunk_bindings", allowing the build tool to read rich type information beyond what the WASM import table provides.

### web/canvas.zig -- Canvas 2D API

27 extern function declarations with ergonomic Zig wrappers:

- Context: `getContext2D(id)`, `getWebGPUSurface(id)`, `setSize(ctx, w, h)`
- Drawing: `fillRect`, `strokeRect`, `clearRect`
- Paths: `beginPath`, `moveTo`, `lineTo`, `arc`, `fill`, `stroke`, `closePath`
- Style: `setFillColor(Color)`, `setStrokeColor(Color)`, `setLineWidth`, `setGlobalAlpha`
- Transform: `translate`, `rotate`, `scale`, `save`, `restore`
- Text: `fillText`, `setFont`

**Color** is a struct with `.r`, `.g`, `.b`, `.a` fields (all u8, alpha defaults to 255).

All functions take a `Ctx2D` handle (obtained from `getContext2D`) as their first argument, matching the browser's CanvasRenderingContext2D pattern.

### web/input.zig -- Input System

The most complex web module. Uses a **polling model** via shared memory -- JS writes input state directly into WASM linear memory each frame, zero marshalling.

**InputState** -- A packed struct at a known memory location:
```
Keys:       3 x 32-byte bitmaps (down, pressed, released) -- 256 keys
Mouse:      x, y, dx, dy (f32); wheel, wheel_x (f32); 3 button bitmaps (down, pressed, released); modifier bits
Touch:      10 slots, each with id, x, y, active flag
Gamepad:    connected flag, 4 axes (f32), 32-bit button mask
Viewport:   width, height (u32), device pixel ratio (f32)
Focus:      bool
Typed:      length + 64-byte UTF-8 buffer (whole code points; no control codes, no Ctrl/Cmd chords)
```

**Coordinate space.** All pointer and viewport fields (`mouse_x/y`, `mouse_dx/dy`, `touch_x/y`, `viewport_width/height`) are in **CSS pixels**. This matches the `w, h` arguments passed to the optional `resize(w, h)` export. The canvas backing store is sized to `w * device_pixel_ratio` by `h * device_pixel_ratio` on HiDPI displays for crisp rendering; consumers who need the device-pixel size (e.g. for a WebGPU viewport) should multiply by `device_pixel_ratio` themselves.

**Pointer and keyboard behavior** (generated JS, `emitInputSystem`):
- Pointer coordinates are canvas-relative CSS pixels. `mousedown` is canvas-scoped; `mousemove`/`mouseup` are window-scoped, so a drag that leaves the canvas still reports its release. Window `blur` releases every held key and button.
- Buttons are left/middle/right (`isMouseButtonPressed/Released` give per-frame edges; a press and release inside one frame both register).
- Wheel deltas are CSS pixels, positive = down/right; line- and page-mode wheels are scaled to pixels. `wheel_x` carries horizontal scroll. A trackpad pinch arrives as a wheel event with `getModifiers().ctrl` set.
- `getModifiers()` reports shift/ctrl/alt/meta of the most recent event.
- Typed text is UTF-8 (`TextEncoder`), never a truncated UTF-16 unit.
- The canvas calls `preventDefault` on wheel, `contextmenu`, middle-click, and (outside form fields) Tab, Space, arrows, Page/Home/End, Backspace/Delete, printable keys and Ctrl/Cmd+A/C/X/V/Y/Z. Other browser shortcuts (F5, F12, Ctrl+R ...) are left alone.

**Key** -- Enum with 120+ named constants mapping to JavaScript key codes.

**Query functions**: `isKeyDown(.space)`, `isKeyPressed(.enter)`, `isKeyReleased(.escape)`, `getMouse()`, `isMouseButtonPressed(.left)`, `isMouseButtonReleased(.left)`, `getTouch(index)`, `getGamepad()`, `getViewportSize()`, `getDevicePixelRatio()`, `hasFocus()`, `getTypedChars()`.

The `init()` function calls an extern to tell JS where the InputState struct lives in WASM memory. The `poll()` function is called each frame to synchronize.

### web/audio.zig -- Web Audio API

Minimal but functional: `init(sample_rate)`, `load(url)`, `loadFromMemory(data)`, `decodeAsset(handle)`, `play(buffer)`, `resume()`, `suspend()`, `setMasterVolume(volume)`.

`decodeAsset` bridges the asset and audio modules: it takes a raw asset handle (an ArrayBuffer from `web.asset.fetch`) and decodes it as audio via `decodeAudioData`. This enables the two-stage pattern: generic fetch, then type-specific decode.

### web/asset.zig -- Generic Asset Loading

Fetches arbitrary assets from URLs at runtime. The browser's `fetch()` API loads the data; WASM code polls for completion and copies bytes into linear memory.

Public API: `fetch(url)`, `isReady(handle)`, `getLen(handle)`, `getBytes(handle, dest)`.

The asset handle stores a raw `ArrayBuffer` in the JS handle table. Type-specific modules (like `audio.decodeAsset`) consume these raw buffers for further processing. This separation means new asset types (images, JSON, binary data) only need a decoder function, not new fetch plumbing.

### web/gpu.zig -- WebGPU Bindings

Typed WebGPU wrappers over 50 extern functions, covering the compute pipeline and a full 3D render path. The lifecycle rules (handles, frame encoder, async operations) are documented once, at the top of `src/web/gpu.zig`; the summary:

- **Handles.** Every GPU object is a `bind.Handle` (index into a JS table; 0 = none, 1 = device). Passes, encoders and command buffers are single-use and released by the call that consumes them. The *frame encoder* and the *canvas view* are created lazily per frame and released by `present`.
- **Frame model.** `beginRenderPassDesc` records into the frame encoder; `present` finishes and submits it. Offscreen passes live in the same encoder, so a later pass can sample an earlier one's result. `frameEncoder()` exposes it for copies and compute.
- **Async = polling.** WASM cannot await. `createTextureFromAsset` is polled with `isTextureReady`; buffer readback is a named state machine `MapState` (`idle -> pending -> mapped | failed -> idle`) driven by `bufferMapRead` / `bufferMapState` / `bufferReadMapped` / `bufferUnmap`. `Readback` wraps texture -> CPU copies (256-byte row alignment included).

3D surface:

- **Resources**: `createBuffer` (any usage incl. `INDEX`), `createTexture`, `createTextureMultisampled`, `createDepthTexture`, `createRenderTarget` (RENDER_ATTACHMENT | TEXTURE_BINDING | COPY_SRC), `createTextureView`, `createTextureFromAsset`, samplers, bind groups.
- **Pipelines**: `createRenderPipelineDesc(RenderPipelineDescriptor)` with colour format (default: canvas format, see `canvasFormat`, `canvasSize`), `BlendMode` (none / alpha / premultiplied / additive), `PrimitiveTopology` (triangle-list, line-list, ...), `CullMode`, `FrontFace`, `DepthState` (format, write, compare, bias, slope bias) and `sample_count`. `createRenderPipeline` / `createRenderPipelineHDR` remain as thin wrappers.
- **Passes**: `beginRenderPassDesc(RenderPassDescriptor)`: colour view (null = canvas), MSAA resolve view, depth view, load/store ops, clear values. `renderPassSetIndexBuffer` + `renderPassDrawIndexed`, `renderPassDraw` with `instance_count`/`first_instance` (vertex buffers with `step_mode = .instance` advance per instance), viewport and scissor.
- **Readback**: `copyTextureToBuffer`, `Readback`.
- **Stencil** is intentionally not exposed (no stencil formats or ops).

Compute and the original API are unchanged: `createComputePipeline`, `computePass*`, `createCommandEncoder`, `encoderFinish`, `queueSubmit`, `beginRenderPass(r,g,b,a)`, `beginRenderPassHDR`.

ABI-matched structs read directly by JS via DataView: `BindGroupLayoutEntry` (40 bytes), `BindGroupEntry` (32), `VertexBufferLayout` / `VertexAttribute` (16), `RawPipelineDesc` (76), `RawPassDesc` (48). `js_resolve.zig` has a test that every `zunk_gpu_*` extern in `gpu.zig` resolves.

### web/ui.zig -- HTML UI Overlay

A DOM-based overlay UI for debug panels and controls, rendered via generated JavaScript:

- **Panels**: `createPanel`, `showPanel`, `hidePanel`, `togglePanel`
- **Controls**: `addSlider`, `addCheckbox`, `addButton`, `addSeparator`
- **Reading values**: `getFloat`, `getBool`, `isClicked`
- **Labels/status**: `setLabel`, `setStatus`
- **Fullscreen**: `requestFullscreen`

Styled with CSS injected into the generated HTML when UI imports are detected.

### web/imgui.zig -- Immediate-Mode Canvas UI

A comptime-generic `Ui(Backend)` that renders immediate-mode widgets directly on a Canvas2D (or future WebGPU) surface. Unlike `web/ui.zig` which creates DOM elements, this draws everything from WASM.

Includes a `Theme` struct with configurable colors, sizing, and fonts. Layout system supports vertical/horizontal nesting up to 16 levels deep.

### web/render_backend.zig -- Render Backend Abstraction

Defines the `Canvas2DBackend` and a `validateBackend` comptime function that checks for required methods (`drawFilledRect`, `drawText`, `measureText`, `setClipRect`, etc.). This allows `imgui.zig` to work with different renderers.

### web/app.zig -- Lifecycle Utilities

`setTitle()`, `openUrl()`, `setCursor()`, `performanceNow()`, `clipboardWrite()`, and leveled logging (`logDebug/Info/Warn/Err`).

### gen/wasm_analyze.zig -- WASM Binary Parser

Parses a `.wasm` binary and produces an `Analysis`:

```
Analysis {
    imports:   []Import     -- module, name, type_idx, func_type, param_names
    exports:   []Export     -- name, kind (func/table/memory/global), index
    func_types: []FuncType  -- params: []WasmValType, returns: []WasmValType
    explicit_manifest: ?[]const u8  -- "zunk_bindings" custom section bytes
    has_name_section: bool
}
```

Handles WASM sections:
- **Type section (0x01)** -- function signatures
- **Import section (0x02)** -- extern declarations with module/name/type
- **Export section (0x07)** -- exported symbols
- **Custom sections (0x00)** -- "name" section for debug info, "zunk_bindings" for manifest

Includes proper LEB128 variable-length integer decoding. Links each import to its FuncType after parsing. Extracts parameter names from the WASM name section when available (debug builds).

### gen/js_resolve.zig -- 5-Tier Auto-Resolution Engine

The core "magic" of zunk. Given a WASM import (name + signature), determines the JavaScript implementation.

**Resolution** -- Output of the resolver:
```
Resolution {
    js_body:              []const u8     -- the JS function body
    needs_handles:        bool           -- requires handle table helper
    needs_string_helper:  bool           -- requires readStr helper
    needs_callbacks:      bool           -- requires callback invoker
    needs_memory_view:    bool           -- requires memory view helper
    confidence:           Confidence     -- exact, high, medium, low, stub
    category:             Category       -- console, canvas2d, input, audio, etc.
}
```

**The 5 Tiers:**

**Tier 1 -- Exact Match.** Import name matches a known Web API function verbatim. 23+ entries covering: `console_log`, `console_error`, `performance_now`, `random`, `date_now`, `setTimeout`, `setInterval`, `requestAnimationFrame`, `clipboard_write`, `storage_set/get/remove`, etc. All resolve at `exact` confidence.

**Tier 2 -- Prefix Match.** Import name starts with a known namespace prefix. This is the workhorse tier:

| Prefix | Generator | Coverage |
|--------|-----------|----------|
| `zunk_canvas_*` | genCanvas | Canvas element ops (get_2d, set_size) |
| `zunk_c2d_*` | genCanvas2D | 2D context methods (fill_rect, arc, etc.) |
| `zunk_input_*` | genInput | Input system (init, poll, callbacks) |
| `zunk_audio_*` | genAudio | Web Audio (init, load, play, decode_asset) |
| `zunk_asset_*` | genAsset | Generic asset loading (fetch, is_ready, get_len, get_ptr) |
| `zunk_app_*` | genApp | Lifecycle (set_title, cursor, log, perf) |
| `zunk_gpu_*` | genWebGPU | WebGPU (one-line bodies; multi-line logic in the generated `zunkGPU` helper) |
| `canvas_*`, `input_*`, etc. | (same) | Generic prefixes (no `zunk_` prefix) |

Each generator function produces the exact JS needed for that operation, setting the appropriate feature requirement flags.

**Tier 3 -- Signature Inference.** Combines WASM type signature with name keywords. Examples:
- `(i32, i32) -> void` + name contains "log" --> string console output
- `() -> f64` + name contains "time" or "now" --> `performance.now()`
- `(i32) -> void` + name contains "free" --> handle release

**Tier 4 -- Parameter Name Inference.** Uses debug symbol names from the WASM name section (when available) to infer intent based on parameter naming patterns.

**Tier 5 -- Stub Generation.** Fallback: generates `console.warn('[zunk] unresolved: ...')` and returns a zero/undefined. The build report lists all stubs so the developer knows exactly what to fix.

**Category** -- Categories for grouping: console, performance, dom, canvas2d, webgpu, audio, input, asset, fetch, websocket, storage, timer, clipboard, lifecycle, zunk_internal, unknown.

### gen/js_gen.zig -- JS + HTML Code Generator

Takes an `Analysis` and `GenOptions`, produces complete JS + HTML output.

**GenOptions**:
- `wasm_filename` -- filename of the .wasm binary
- `public_url` -- URL prefix for assets (default: "/")
- `bridge_js` -- optional custom JS to merge in
- `js_filename` -- output JS filename (default: "app.js", deploy uses hashed names)
- `wasm_preload` -- emit `<link rel="preload">` for the WASM file (deploy mode)
- `js_integrity` -- SRI hash for the script tag (deploy mode)
- `verbose_report` -- show all resolutions grouped by category (not just stubs)
- `json_report` -- emit machine-readable JSON instead of rich text

**Generation steps:**

1. Resolve all imports via js_resolve
2. Scan resolutions to determine which features are needed (handles, strings, callbacks, input system, audio state, fetch state)
3. Emit only the helpers that are actually required
4. Build the `env` object with all resolved import implementations
5. Emit WASM instantiation code
6. Wire up lifecycle exports (init, frame, resize, cleanup)
7. Generate HTML with canvas element, meta tags, styles, script tag

**Adaptive output** -- The generated JS includes only what the WASM binary actually uses. A console-only app gets ~1KB of JS. A full game with canvas, input, and audio is still under 10KB.

### main.zig -- CLI Entry Point

Supports: `build`, `run`, `deploy`, `init`, `doctor`, `help`, `version`.

Shared infrastructure via `prepareBuild()`:
1. Parses CLI args (--wasm, --output-dir, --port, --proxy, --no-watch, --verbose, --report-json, --force)
2. Reads the .wasm binary
3. Runs `wasm_analyze.analyze()` to parse imports/exports/types
4. Auto-discovers `bridge.js` from project root or `js/` directory

The `build` command:
1. Checks build cache (mtime fingerprint of src/*.zig, build.zig*, wasm, bridge.js); skips if up-to-date (unless `--force`)
2. Calls `js_gen.generate()` to produce JS + HTML
3. Writes `dist/index.html`, `dist/app.js`, and the .wasm file
4. Copies `src/assets/` to `dist/assets/` if the directory exists
5. Prints the resolution diagnostic report (color-coded, with "did you mean?" suggestions for stubs)
6. Writes cache fingerprint on success

The `run` command: same as `build`, then launches the dev server with live reload.

The `deploy` command (production build):
1. Checks build cache (same as build); skips if up-to-date (unless `--force`)
2. Computes content hashes (XxHash3) for WASM and JS filenames
3. Generates JS with the hashed WASM filename embedded in the fetch() call
4. Computes SHA-384 SRI hash for the JS output
5. Generates HTML with hashed script/wasm references, SRI integrity attribute, and WASM preload hint
6. Writes content-hashed files to `dist/`
7. Writes cache fingerprint on success

The `init` command:
1. Accepts optional subdirectory name (defaults to current directory)
2. Guards against re-initialization (aborts if `build.zig` exists)
3. Scaffolds 4 files from comptime templates: `build.zig`, `build.zig.zon`, `src/main.zig`, `.gitignore`

The `doctor` command:
1. Checks zig version (spawns `zig version`, parses semver, validates >= 0.15.2)
2. Reports wasm32 target availability (bundled with zig)
3. Checks project structure (`build.zig`, `build.zig.zon`, `src/main.zig`)
4. Checks `.gitignore` presence (warns about dist/ being committed)
5. Prints color-coded OK/WARN/FAIL status per check with a summary line

Auto-compilation is handled by `installApp()` in the user's `build.zig`.

## Memory Model

| Data Type | Strategy | Overhead |
|-----------|----------|----------|
| Scalars (i32, f32, etc.) | Direct WASM params/returns | Zero |
| Opaque JS objects | Handle table (integer ID <-> JS object Map) | 1 Map lookup |
| Strings (Zig -> JS) | Pointer + length into WASM linear memory | 1 TextDecoder call |
| Strings (JS -> Zig) | Shared 64KB exchange buffer | 1 memcpy |
| Input state | Shared memory struct (JS writes directly) | Zero marshalling |
| Callbacks (JS -> Zig) | Callback table (integer ID -> function pointer) | 1 table lookup |

## Lifecycle Protocol

zunk detects these exports from the WASM binary and wires them up automatically:

| Export | Signature | When Called |
|--------|-----------|-------------|
| `init` | `fn() void` | Once, after WASM + canvas ready |
| `frame` | `fn(dt: f32) void` | Every `requestAnimationFrame` |
| `resize` | `fn(w: u32, h: u32) void` | On window/canvas resize |
| `cleanup` | `fn() void` | On `beforeunload` (optional) |

If `frame` is exported, the JS generator emits a render loop. If `resize` is exported, it emits a resize handler with fullscreen canvas. Everything is conditional.

**Canvas ownership and resize contract.** The generated HTML declares a full-viewport `<canvas id="app">`. zunk's runtime owns the backing-store size: on window resize (and on initial load), it sets `canvas.width = clientWidth * devicePixelRatio` and `canvas.height = clientHeight * devicePixelRatio`, then calls `resize(w, h)` with the **CSS-pixel** size. The consumer never touches `canvas.width` / `canvas.height`. WebGPU apps that need the device-pixel swap-chain size multiply the arguments by `getDevicePixelRatio()` themselves. A DPR-change listener (via `matchMedia`) is installed on the WebGPU path so moving between displays triggers the same flow.

## Host-Async Bridge Pattern (Request / Poll)

Some browser APIs are intrinsically asynchronous and gesture-gated -- they cannot be wedged into a synchronous `extern fn` return. The File System Access API (`showOpenFilePicker`, `showSaveFilePicker`) is the canonical case: the picker only opens during a user-gesture turn, and the resolution lands on a future microtask.

zunk handles these by splitting the call into a **request** (synchronous import that fires the JS-side work) and a **result callback** (wasm export that the JS bridge invokes when the promise resolves). The Zig caller correlates the two with an integer request id and polls a local slot table on subsequent frames. This pattern keeps the wasm side fully synchronous while honoring the browser's async contract.

### File Dialog (issue #14)

Wasm-side import (call from inside an update driven by a user-gesture Msg):

```zig
extern "env" fn __zunk_request_file_dialog(
    id: u32,
    mode: u32,                       // 0 = open, 1 = save
    name_ptr: [*]const u8,           // filter description (e.g. "Zig sources")
    name_len: u32,
    pattern_ptr: [*]const u8,        // Win32-style globs, ";" joined ("*.zig;*.zon")
    pattern_len: u32,
) void;
```

Wasm-side export the bridge invokes when the picker resolves or rejects:

```zig
pub export fn __zunk_file_dialog_result(
    id: u32,
    path_ptr: [*]const u8,           // points into the shared 64 KB exchange buffer
    path_len: u32,                   // 0 = cancelled / unsupported / failed
) void { ... }
```

zunk's JS bridge writes the chosen filename into the shared `__zunk_string_buf_ptr` region before calling the export, so consumers must copy the bytes out during the callback (the buffer is reused for any subsequent JS->Zig string transfer). Browsers without the File System Access API (Firefox / Safari today) take the cancel path -- a `console.warn` lands once per request and `__zunk_file_dialog_result` is invoked with `path_len == 0`. Ship a `bridge.js` override (e.g. `<input type="file">` fallback) when broader support is needed.

**Gesture-gating.** The request must originate inside the same synchronous turn as the user input. Polling-style dispatch (input.poll() -> frame() -> request) works because the browser keeps "transient activation" for a few seconds after a click/keydown, and the frame callback fires well within that window. Calling the request from a setTimeout or async tick will throw a `SecurityError` inside the picker.

## Host services (`web.fx`)

`zunk.web.fx` (Zig, `src/web/fx.zig`) + `src/gen/js/fx.js` (JS) cover the asynchronous browser work an application needs: `fetch`, file downloads, a file picker, `localStorage`, the wall clock, URL query parameters, clipboard writes, and pasted / dropped images and files. It generalizes the request / poll idea above: **one** completion channel instead of one callback per feature. The JS is emitted only when the wasm imports a `zunk_fx_*` function.

### Requests (wasm -> JS)

Plain imports that return at once. JS copies whatever it needs out of wasm memory *before returning* (wasm memory may move or be reused afterwards), so callers may free or reuse their buffers immediately.

| Zig | Import | Result |
|---|---|---|
| `fx.http(id, method, url, headers, body, timeout_ms)` | `zunk_fx_http` | `http`: status (0 = transport failure), body, error text |
| `fx.download(id, name, mime, bytes)` | `zunk_fx_download` | `downloaded` ok flag (Blob + temporary `<a download>`) |
| `fx.openFile(id, accept)` | `zunk_fx_open_file` | `file_opened` name/mime/bytes, or `file_cancelled` |
| `fx.storageGet(id, key)` / `fx.storageSet(key, value)` | `zunk_fx_storage_*` | `storage_value`; set has no result, an empty value deletes |
| `fx.clock(id)` | `zunk_fx_clock` | `clock`: unix ms + UTC offset minutes |
| `fx.queryParam(id, name)` | `zunk_fx_query_param` | `query_value` |
| `fx.clipboardWrite(text)` | `zunk_fx_clipboard_write` | none (`navigator.clipboard.writeText`, `execCommand('copy')` fallback) |

HTTP: request body up to ~8 MB and response bodies up to 32 MB are supported; a failed request (network error, CORS, timeout via `AbortController`, oversized response) completes with status 0 and a readable message. `encodeHeaders` turns a slice of `{name, value}` into the header text and drops headers that could smuggle another.

### Completions (JS -> wasm)

Every result, solicited or not, is a *completion record* queued in JS. Wasm collects them with `fx.poll(out: []Completion)`, once per frame:

1. `poll` frees the previous batch, then calls the import `zunk_fx_pump(max)`.
2. For each queued record (at most `max`) JS calls the exported `zunk_fx_alloc(len)` (allocates in wasm memory; re-read `memory.buffer` afterwards, the allocation may have grown it), copies the record in, and calls the exported `zunk_fx_deliver(ptr, len)`.
3. `poll` decodes the records into `Completion { kind, id, a, b, c, d, blobs[4] }` whose slices **alias the delivered memory and stay valid until the next `poll`**.

JS calls into wasm only inside `zunk_fx_pump`, never from a promise callback or event handler, so wasm state is never touched mid-frame, and a frame loop that polls every frame leaks nothing. Records beyond `max` stay queued in JS (an unsolicited backlog is capped at 64, oldest dropped).

Record layout (little endian; the table of per-kind fields is in `fx.js` and the `Completion` doc comment): `u32 kind, u32 id` (0 = unsolicited), `i32 a b c d`, `u32 len0..len3`, then the four blobs back to back.

### Handle and id conventions

Requests that expect an answer take a caller-chosen **id >= 1**, echoed in the completion. There are no JS handles: a request is identified only by its id, and unsolicited completions (paste, drop) carry id 0. The caller owns uniqueness.

### The file picker and user activation

Browsers open a picker only from a user activation. The effect that asks for a file is usually issued a frame after the click; `navigator.userActivation.isActive` is checked, and if the activation is still live the picker opens at once. If not, the request is **armed**: the picker opens on the next pointer press or key press. A new request cancels an armed or open one. The hidden `<input type="file" id="zunk-fx-file">` fires `cancel` when the user dismisses it.

### Paste and drop

`paste` and `drop` listeners on `document` turn clipboard / dropped data into `dropped` and `pasted_text` completions. Images are decoded with `createImageBitmap`, scaled so the long side is at most 1568 px, and re-encoded as PNG (a JPEG that needed no scaling keeps its bytes); a 64 px long-side RGBA thumbnail is produced alongside. Other files arrive as `kind = file` (up to 32 MB), dropped text as `kind = text`. Ctrl/Cmd+V is no longer swallowed by the input system, and is reported to wasm *together with* its paste event (or after 80 ms without one), so a host that reads the clipboard when it sees the key finds the data in the same frame.

## Web fonts

`zunk build --font <family> <weight> <path>` (repeatable; `InstallAppOptions.fonts` in `build.zig`) copies the file to `dist/fonts/<basename>`, adds an `@font-face` rule to the page, and makes the generated JS `await document.fonts.load(...)` for every face before `init()` runs, so the first text measurement already sees the real font. A font that fails to load logs a warning and startup continues. `zunk deploy` copies fonts the same way (names are not hashed).

## Per-Frame Allocation Pattern

wasm-freestanding has no libc `malloc`, so consumers bring their own allocator. For game-loop-style code where allocations live at most one frame (command buffers, vertex scratch, UI retained-mode state), a `std.heap.ArenaAllocator` with `reset(.retain_capacity)` called at the end of each `frame()` is a good default:

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var frame_arena = std.heap.ArenaAllocator.init(gpa.allocator());

export fn frame(dt: f32) void {
    defer _ = frame_arena.reset(.retain_capacity);
    const scratch = frame_arena.allocator();
    // ... use `scratch` freely; nothing leaks across frames
}
```

A `FixedBufferAllocator` also works and is zero-dependency, but has no piecewise free -- so any collection that doesn't itself implement capacity retention (`std.ArrayList.clearRetainingCapacity`, `std.AutoHashMap.clearRetainingCapacity`, etc.) leaks monotonically. Prefer the arena for mixed allocation shapes.

zunk itself is allocator-agnostic and does not ship a bundled arena helper; the above is a convention, not an API.

## Three Usage Paths

All three coexist. Use whichever fits:

**Path 1 -- Raw extern fns (zero config).**
Declare `extern "env" fn` with naming conventions. zunk reads the WASM import table and auto-resolves from the knowledge base.

**Path 2 -- Layer 2 modules (ergonomic).**
Import `@import("zunk").web.canvas` etc. Pre-built typed wrappers that declare the externs and provide nice Zig APIs.

**Path 3 -- bridge.js (escape hatch).**
Ship custom JavaScript alongside your project or library. zunk merges it into the generated output for APIs it doesn't have built-in support for.

## Comparison with wasm-bindgen

| Aspect | wasm-bindgen (Rust) | zunk (Zig) |
|--------|---------------------|------------|
| Binding definition | Proc macro attributes | Comptime descriptors + extern fn |
| When JS is generated | Post-processing step on .wasm | During zunk build (reads .wasm imports) |
| JS output size | ~50KB+ for hello-world | ~1KB for hello-world |
| Complex types | Serde-based serialization | Shared memory + handles |
| String passing | Copies through JS heap | Direct linear memory reads |
| Callback model | Complex closure wrapping | Simple callback table (id -> fn ptr) |
| Build steps | cargo build -> wasm-bindgen -> bundler | zunk run (one step) |
| Input handling | Per-event callbacks (async) | Polling model (sync, game-friendly) |
