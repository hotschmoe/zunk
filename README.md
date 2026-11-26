# ⚡ zunk

**Write web apps in pure Zig. No JavaScript. No HTML. Just Zig.**

zunk is a build tool and runtime library that lets you write browser applications entirely in Zig, compiled to WebAssembly. It automatically generates all the HTML and JavaScript required to run your app — you never touch either.

```zig
const zunk = @import("zunk");
const canvas = zunk.web.canvas;
const input = zunk.web.input;

var ctx: canvas.Ctx2D = undefined;

export fn init() void {
    input.init();
    ctx = canvas.getContext2D("app");
}

export fn frame(dt: f32) void {
    input.poll();
    canvas.clearRect(ctx, 0, 0, 800, 600);
    canvas.setFillColor(ctx, .{ .r = 255, .g = 100, .b = 50 });
    canvas.fillRect(ctx, 100, 100, 50, 50);
}
```

```
$ zig build run
```

`zunk init` writes the `build.zig` that wires this up. `zig build run` compiles the wasm, generates `dist/`, serves it, and rebuilds and reloads when the source changes.

---

## Goals

### Primary

- **Pure Zig web development.** A developer should be able to build a complete browser application — games, tools, visualizations, creative apps — writing only Zig. No JavaScript, no HTML templates, no config files required.

- **One call to set up, full control when needed.** A project needs one `zunk.installApp(...)` call in its `build.zig`; `zig build run` does the rest. Every layer is overridable.

- **Automatic JS generation from WASM analysis.** Zunk reads the compiled `.wasm` binary, inspects every `extern "env" fn` import, and auto-generates the matching JavaScript implementations using a multi-tier resolution engine. No manual binding descriptors needed for common Web APIs.

- **Replace wasm-bindgen for Zig.** Rust needs wasm-bindgen because it can't introspect types at compile time. Zig has comptime. The binding definition IS the code — no separate post-processing tool, no proc macros, no code generation step. Zunk leverages Zig's strengths rather than porting Rust's workarounds.

### Secondary

- **Serve the Zig WebGPU ecosystem.** Zunk pairs with native Zig WebGPU UI libraries. [teak](https://github.com/hotschmoe/teak) builds its web backend on `zunk.web.gpu`, and its needs drive most of the WebGPU surface here.

- **Ship small.** Zunk only emits scaffolding for features the WASM actually imports. Measured, unminified: a console-only hello-world generates about 2 KB of JavaScript, the canvas + input example about 12 KB, a WebGPU example about 21 KB.

- **Fast iteration.** `zig build run` builds, serves, and watches `src/` and `build.zig*`. A change reruns `zig build` and the browser reloads; compile errors show as an overlay in the page. `--hmr` swaps the wasm in place instead of reloading.

- **Production-ready output.** `zunk deploy` produces a `dist/` directory with content-hashed filenames, subresource integrity attributes, and preload hints — ready to drop onto any static file server (nginx, S3, Cloudflare Pages, etc.).

### The Vision

[CyberEther](https://github.com/luigifcruz/cyberether) is a case study for what WebAssembly, WebUSB, and WebGPU can achieve together: a GPU-accelerated signal processing framework with a flowgraph editor, real-time visualization, and cross-platform deployment -- all running in the browser via WebGPU without installation. It targets Vulkan, Metal, and WebGPU from one codebase.

A developer should be able to write something that ambitious and beautiful in 100% Zig, and zunk should handle the JS/HTML generation.

### Non-Goals (for now)

- Server-side rendering or SSR
- Package registry or dependency resolution (use Zig's build system)
- Framework opinions — zunk is a build tool + platform layer, not a UI framework (that is teak)
- Support for languages other than Zig

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    Developer's Zig Code                       │
│  (pure Zig — imports zunk runtime OR raw extern fns)         │
└──────────┬───────────────────────────────────────────────────┘
           │ zig build → .wasm
           ▼
┌──────────────────────────────────────────────────────────────┐
│                    WASM Analyzer                              │
│  Reads import section, export section, type section,         │
│  name section (debug), and custom sections from .wasm        │
└──────────┬───────────────────────────────────────────────────┘
           │ import list + signatures
           ▼
┌──────────────────────────────────────────────────────────────┐
│               5-Tier Auto-Resolution Engine                   │
│                                                               │
│  T1: Exact match    — known Web API name         [exact]     │
│  T2: Prefix match   — namespace convention       [exact]     │
│  T3: Signature       — types + name keywords     [high]      │
│  T4: Param names    — debug section hints        [medium]    │
│  T5: Stub           — warning + build report     [stub]      │
└──────────┬───────────────────────────────────────────────────┘
           │ resolved bindings
           ▼
┌──────────────────────────────────────────────────────────────┐
│                   JS Code Generator                           │
│                                                               │
│  Emits ONLY the scaffolding actually needed:                 │
│  • Handle table (if JS objects are referenced)               │
│  • String helpers (if strings cross the boundary)            │
│  • Input system (if input imports exist)                     │
│  • Render loop (if WASM exports `frame`)                     │
│  • Resize handler (if WASM exports `resize`)                 │
│  • Audio state, fetch state, etc.                            │
│                                                               │
│  Also generates HTML: canvas, meta tags, styles              │
└──────────┬───────────────────────────────────────────────────┘
           │
           ▼
     dist/
     ├── index.html              (generated)
     ├── app.js                  (generated; app-[hash].js with `zunk deploy`)
     └── <name>.wasm             (compiled; <name>-[hash].wasm with `zunk deploy`)
```

### Three Usage Paths

All three coexist in the same project. Use whichever fits your needs:

**Path 1 — Zero config (raw extern fns)**
```zig
// Just declare what you need. Zunk figures out the JS.
extern "env" fn ctx2d_fill_rect(ctx: i32, x: f32, y: f32, w: f32, h: f32) void;
extern "env" fn performance_now() f64;
extern "env" fn console_log(ptr: [*]const u8, len: u32) void;
```
Zunk reads the `.wasm` import table and auto-resolves from naming conventions and signatures.

**Path 2 — Ergonomic (Layer 2 web modules)**
```zig
const zunk = @import("zunk");
const canvas = zunk.web.canvas;
const input = zunk.web.input;
const audio = zunk.web.audio;
const app = zunk.web.app;
```
Pre-built typed wrappers with nice Zig APIs. Polling-based input, handle types, color structs.

**Path 3 — Custom (bridge.js escape hatch)**
```zig
extern "env" fn my_webrtc_connect(url_ptr: [*]const u8, url_len: u32) i32;
```
Ship a `bridge.js` alongside your project or library. Zunk merges it into the generated output.

#### Shipping a `bridge.js` in a Zig library

A Zig package that exposes its own browser-side JS places a `bridge.js` at the package root (next to `build.zig.zon`). Consumers opt in via `zunk.installApp`:

```zig
// consumer's build.zig
const zunk = b.dependency("zunk", .{ .target = wasm_target, .optimize = optimize });
const teak = b.dependency("teak", .{ .target = wasm_target, .optimize = optimize });

@import("zunk").installApp(b, zunk, exe, .{
    .bridge_deps = &.{ teak },  // merges teak's bridge.js automatically
});
```

**Merge order.** Dep-provided chunks are emitted first, in the order listed in `bridge_deps`. The consumer's own `bridge.js` (at repo root or `js/bridge.js`) is emitted last, so it can override symbols from deps. Each chunk is prefixed with a banner comment naming its origin.

**Filename is fixed** (`bridge.js`). Listing a dep that has no such file will fail loudly when the build step runs — that is the correct behavior.

### Web API Coverage (built-in resolution)

| Domain | Prefix | Examples |
|--------|--------|---------|
| Console | `console_*`, `log_*` | `console_log`, `log_i32`, `log_f64` |
| DOM | `dom_*` | `dom_set_text`, `dom_set_html`, `dom_query`, `dom_create_element` |
| Canvas 2D | `canvas_*`, `ctx2d_*` | `canvas_get_2d`, `ctx2d_fill_rect`, `ctx2d_arc` |
| WebGPU | `gpu_*` | `gpu_create_buffer`, `gpu_create_shader_module`, `gpu_begin_render_pass` |
| Web Audio | `audio_*` | `audio_init`, `audio_load`, `audio_play` |
| Input | `input_*` | `input_init`, `input_poll` |
| Fetch | `fetch_*` | `fetch_get`, `fetch_get_response_ptr` |
| WebSocket | `ws_*` | `ws_connect`, `ws_send`, `ws_close` |
| Storage | `storage_*` | `storage_set`, `storage_get`, `storage_remove` |
| HTML overlay UI | `ui_*` | `ui_create_panel`, `ui_add_slider`, `ui_get_float` |
| Timers | — | `setTimeout`, `setInterval`, `requestAnimationFrame` |
| Clipboard | `clipboard_*` | `clipboard_write` |
| Performance | — | `performance_now`, `random`, `date_now` |

The Layer 2 modules use the same names behind a `zunk_` prefix. An import that matches nothing gets a stub that warns at runtime, and the build report lists it with a "did you mean" suggestion.

### Lifecycle Protocol

Zunk detects these exports from your WASM and wires them up automatically:

| Export | Signature | When Called |
|--------|-----------|-------------|
| `init` | `fn () void` | Once after WASM + canvas ready |
| `frame` | `fn (dt: f32) void` | Every `requestAnimationFrame` |
| `resize` | `fn (w: u32, h: u32) void` | On window resize |
| `cleanup` | `fn () void` | On `beforeunload` |

If you export `frame`, zunk generates a render loop. If you export `resize`, zunk generates a resize handler. An app that draws (canvas or WebGPU imports) and exports `frame` gets a full-window canvas.

### Host services and web fonts

`zunk.web.fx` wraps the async browser work apps need behind one poll-style completion channel: `fetch` (headers, ~8 MB bodies, timeout), downloads, a file picker that waits for a user activation, `localStorage`, the clock, URL query parameters, clipboard writes, and pasted / dropped images (downscaled, re-encoded, thumbnailed) and files. `zunk build --font <family> <weight> <path>` (or `InstallAppOptions.fonts`) ships web fonts and holds startup until they load. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) ("Host services", "Web fonts").

### Memory Model

| Data Type | Strategy | Overhead |
|-----------|----------|----------|
| Scalars (i32, f32, etc.) | Direct WASM params/returns | Zero |
| Opaque JS objects | Handle table (integer ID ↔ JS object Map) | 1 Map lookup |
| Strings (Zig → JS) | Pointer + length into WASM linear memory | 1 TextDecoder call |
| Strings (JS → Zig) | Shared 64KB exchange buffer | 1 memcpy |
| Input state | Shared memory struct (JS writes directly) | Zero marshalling |
| Callbacks (JS → Zig) | Callback table (integer ID → function pointer) | 1 table lookup |

---

## Project Structure

```
zunk/
  build.zig                     # CLI build, test steps, installApp() for consumers
  src/
    root.zig                    # The "zunk" module: bind, web.*, version
    main.zig                    # CLI (build/run/deploy/init/doctor/help/version)
    bind/
      bind.zig                  # Handle, callback table, string exchange buffer
    web/                        # Layer 2: typed Web API wrappers
      canvas.zig                #   Canvas 2D
      input.zig                 #   Keyboard, mouse, touch, wheel, typed text (polling)
      audio.zig                 #   Web Audio
      asset.zig                 #   URL-based asset loading
      app.zig                   #   Title, cursor, timing, logging, clipboard
      gpu.zig                   #   WebGPU
      fx.zig                    #   Host services (fetch, downloads, file pick, storage, paste/drop)
      ime.zig                   #   IME composition
      ui.zig                    #   HTML overlay UI (panels, sliders, checkboxes, buttons)
      imgui.zig                 #   Immediate-mode canvas UI (comptime backend)
      render_backend.zig        #   Canvas2DBackend for imgui
    gen/                        # Build tool: WASM analysis + JS generation
      wasm_analyze.zig          #   WASM binary parser (imports, exports, types, names)
      js_resolve.zig            #   Resolution engine + Web API knowledge base
      js_gen.zig                #   JS + HTML generator, build report
      source_map.zig            #   Source maps for bridge.js chunks
      serve.zig                 #   Dev server, file watcher, live reload, HMR
      js/                       #   Embedded JS: a11y mirror, host services, IME
  examples/
    input-demo/                 # Keyboard, mouse, touch input
    imgui-demo/                 # Canvas-based immediate-mode UI
    a11y-demo/                  # Accessibility DOM mirror
    file-dialog-demo/           # Async file picker
    audio-demo-1-assets-bundled/  # Web Audio with bundled assets
    audio-demo-2-assets-cached/   # Web Audio with fetched assets
    vertex-triangle/            # Smallest WebGPU app: one vertex buffer, one draw
    texture-demo/               # Texture upload and sampling
    text-demo/                  # Canvas-rasterized text as a WebGPU texture
    atlas-upload/               # R8 atlas sub-rect uploads, cluster raster, instanced quads
    mesh-3d/                    # Depth + stencil, MSAA, instancing, offscreen target, readback
    particle-life/              # WebGPU compute + render, HTML overlay UI
  tools/
    test.mjs                    # Blocking and background end-to-end gates
    release.sh                  # Cut a release
  docs/
    ARCHITECTURE.md             # Design decisions
    ROADMAP.md                  # What is open
    VERSIONING.md               # Version source and release procedure
  SRC.md                        # Per-module notes the code cannot say
  README.md
```

---

## Quick Start

Requires Zig 0.17.1 or newer.

### Install

```bash
git clone https://github.com/hotschmoe/zunk.git
cd zunk
zig build -Doptimize=ReleaseSafe
# Binary at zig-out/bin/zunk
```

### Create a project

```bash
zunk init my-app
cd my-app
```

This creates `build.zig`, `build.zig.zon`, `src/main.zig` (a canvas hello-world), and `.gitignore`. The generated `build.zig.zon` points the `zunk` dependency at `../..`, which is right for a project created under `examples/` of a zunk checkout; anywhere else, change that path or replace it with a `zig fetch --save` of this repository.

The `build.zig` compiles `src/main.zig` to `wasm32-freestanding` and hands the result to `zunk.installApp`, which runs the zunk CLI as a build step.

### Run

```bash
zig build run
# compiles, generates dist/, serves at http://127.0.0.1:8080
```

### Build or deploy

```bash
zig build
# dist/ with index.html, app.js and the .wasm

zunk deploy --wasm zig-out/bin/app.wasm
# dist/ with content-hashed filenames, SRI and a wasm preload hint
```

`zunk build`, `zunk run` and `zunk deploy` take a compiled `.wasm` through `--wasm`; they do not compile Zig themselves.

---

## Comparison

### vs wasm-bindgen (Rust)

wasm-bindgen is a post-processing tool that reads proc macro annotations from the WASM binary and generates JavaScript glue. It exists because Rust cannot introspect types at compile time.

Zunk takes a fundamentally different approach: it reads the WASM import table (which already contains function names and full type signatures) and resolves bindings from a knowledge base + inference engine. No annotations, no proc macros, no post-processing step. Zig's comptime means the binding definition is the code itself.

| | wasm-bindgen | zunk |
|---|---|---|
| Binding definition | Proc macro attributes | Naming convention + type signatures |
| JS generation | Post-process `.wasm` binary | Read `.wasm` imports during build |
| Build steps | `cargo build` → `wasm-bindgen` → bundler | `zig build run` (one command) |
| JS output size | ~50KB+ hello-world | ~2KB hello-world |
| String passing | Copies through JS heap | Direct linear memory reads |
| Input model | Per-event callbacks (async) | Polling (shared memory, game-friendly) |
| Requires | Rust nightly features | Zig 0.17.1 |

### vs Emscripten

Emscripten is a full C/C++ → WASM toolchain that reimplements libc, SDL, OpenGL, and other system libraries as JavaScript. It's comprehensive but heavyweight.

Zunk is minimal. It doesn't reimplement anything — it generates thin bridge code between your WASM exports/imports and native browser APIs. You get WebGPU, not a WebGL emulation of OpenGL. You get Web Audio, not an SDL_mixer shim.

### vs trunk (Rust)

trunk is the direct inspiration for zunk's build tool. It uses an HTML-driven asset pipeline (`<link data-trunk rel="rust" />`) to declare what to build. Zunk takes this further — the HTML is fully auto-generated based on what the WASM needs. No `index.html` template required.

---

## Status

Working today: the WASM analyzer, the resolution engine, the JS/HTML generator, the binding system, the Layer 2 modules (canvas, input, audio, asset, app, gpu, fx, ime, ui, imgui), the dev server with live reload and opt-in HMR, `bridge.js` merging with source maps, web font registration, and `zunk deploy` (content-hashed filenames, SRI, wasm preload). `zunk init` scaffolds a project, `zunk doctor` checks the environment, builds are cached, and the resolution report has "did you mean" suggestions (`--verbose`, `--report-json`).

The WebGPU surface covers what teak and a CAD viewer needed: vertex and index buffers, instancing, samplers, depth and stencil, MSAA, offscreen targets, blend modes, compute, sub-rect texture uploads, and buffer readback. There are twelve examples under `examples/`.

The blocking gate (`zig build test`) builds the CLI, builds one example, and checks `build` and `deploy` output. The background gate (`zig build test-heavy`) builds six more examples and runs `input-demo` and `mesh-3d` (WebGPU) in headless Chrome.

See [docs/ROADMAP.md](docs/ROADMAP.md) for what is open and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for design decisions.

---

## Design Principles

1. **Single source of truth.** The Zig code IS the specification. Both the WASM imports and the generated JavaScript are derived from what the developer writes. Nothing is duplicated.

2. **Explicit over implicit.** Following Zig's philosophy, there's no hidden magic. Every `extern fn` maps to exactly one JavaScript function. The resolution report tells you exactly what was generated and why.

3. **Minimal output.** The generated JavaScript includes only the scaffolding the app's imports need. No framework, no polyfills. A console-only app gets about 2 KB of JS.

4. **Progressive disclosure.** Start with raw `extern fn` declarations. Graduate to the Layer 2 ergonomic wrappers when you want nicer types. Use `bridge.js` when you need something custom. Each level adds convenience without requiring the previous one.

5. **Game-friendly.** The input system uses polling (shared memory written by JS each frame), not event callbacks. This is what game loops actually want — check `isKeyDown(.space)` in your frame function, not register an async callback.

---

## Contributing

The highest-impact contributions right now:

1. **More Web API coverage** -- Web Workers, IndexedDB, WebRTC, WebMIDI, WebXR; the gamepad fields in the input block are reserved but not filled
2. **WebGPU gaps** -- multiple color targets, render bundles, timestamp queries, device-lost and validation-error reporting
3. **Compile from the CLI** -- `zunk build` and `zunk run` need a pre-built `--wasm`; they could run `zig build` and find the output themselves
4. **WASM-to-Zig source maps** -- today's source maps cover `bridge.js` chunks only

Testing follows the owner's [ENGINEERING.md](https://github.com/hotschmoe/hotschmoe-setup/blob/master/ENGINEERING.md): no unit tests, a small blocking end-to-end gate, everything else in the background gate.

---

## License

MIT OR Apache-2.0
