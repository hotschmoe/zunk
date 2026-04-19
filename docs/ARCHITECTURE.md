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
    gpu.zig                 WebGPU bindings (33 extern fns, typed handles)
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
Mouse:      x, y, dx, dy (f32); wheel (f32); 3 button bitmaps (down, pressed, released)
Touch:      10 slots, each with id, x, y, active flag
Gamepad:    connected flag, 4 axes (f32), 32-bit button mask
Viewport:   width, height (u32), device pixel ratio (f32)
Focus:      bool
Typed:      length + 32-byte UTF-8 char buffer (printable characters only)
```

**Coordinate space.** All pointer and viewport fields (`mouse_x/y`, `mouse_dx/dy`, `touch_x/y`, `viewport_width/height`) are in **CSS pixels**. This matches the `w, h` arguments passed to the optional `resize(w, h)` export. The canvas backing store is sized to `w * device_pixel_ratio` by `h * device_pixel_ratio` on HiDPI displays for crisp rendering; consumers who need the device-pixel size (e.g. for a WebGPU viewport) should multiply by `device_pixel_ratio` themselves.

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

Comprehensive WebGPU API wrappers with 33 extern function declarations covering the full render and compute pipeline:

- **Resources**: `createBuffer`, `createShaderModule`, `createTexture`, `createTextureView`, `createHDRTexture`, `createTextureFromAsset`
- **Buffer ops**: `bufferWrite`, `bufferWriteTyped`, `bufferDestroy`, `copyBufferInEncoder`
- **Bind groups**: `createBindGroupLayout`, `createBindGroup`, `createPipelineLayout`
- **Pipelines**: `createComputePipeline`, `createRenderPipeline`, `createRenderPipelineHDR`
- **Command encoding**: `createCommandEncoder`, `encoderFinish`, `queueSubmit`
- **Compute pass**: `beginComputePass`, `computePassSetPipeline`, `computePassSetBindGroup`, `computePassDispatch`, `computePassEnd`
- **Render pass**: `beginRenderPass`, `beginRenderPassHDR`, `renderPassSetPipeline`, `renderPassSetBindGroup`, `renderPassDraw`, `renderPassEnd`
- **Present**: `present` (flushes encoder to screen)

Type-safe handles: `Device`, `Buffer`, `ShaderModule`, `Texture`, `TextureView`, `BindGroupLayout`, `BindGroup`, `PipelineLayout`, `ComputePipeline`, `RenderPipeline`, `CommandEncoder`, `ComputePassEncoder`, `RenderPassEncoder`, `CommandBuffer` -- all `bind.Handle` underneath.

ABI-matched structs `BindGroupLayoutEntry` (40 bytes) and `BindGroupEntry` (32 bytes) are read directly by JS via DataView for zero-copy bind group creation.

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
| `zunk_gpu_*` | -- | WebGPU (stubs, pending implementation) |
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
