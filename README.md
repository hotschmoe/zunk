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
$ zunk run
⚡ zunk building...
  → compiling zig to wasm...
  → resolving 18 imports (18 exact, 0 stubs)
  → generating js (3.2KB) + html
✓ built in 340ms
⚡ zunk serving at http://127.0.0.1:8080
```

That's it. One file. One command.

---

## Goals

### Primary

- **Pure Zig web development.** A developer should be able to build a complete browser application — games, tools, visualizations, creative apps — writing only Zig. No JavaScript, no HTML templates, no config files required.

- **Zero-config by default, full control when needed.** Running `zunk run` on a directory with a `src/main.zig` should just work. But every layer is overridable for advanced use cases.

- **Automatic JS generation from WASM analysis.** Zunk reads the compiled `.wasm` binary, inspects every `extern "env" fn` import, and auto-generates the matching JavaScript implementations using a multi-tier resolution engine. No manual binding descriptors needed for common Web APIs.

- **Replace wasm-bindgen for Zig.** Rust needs wasm-bindgen because it can't introspect types at compile time. Zig has comptime. The binding definition IS the code — no separate post-processing tool, no proc macros, no code generation step. Zunk leverages Zig's strengths rather than porting Rust's workarounds.

### Secondary

- **Serve the Zig WebGPU ecosystem.** Zunk is designed to pair with native Zig WebGPU UI libraries. A developer pulls in a GPU rendering library and zunk, writes their app in pure Zig, and `zunk run` handles the entire browser deployment pipeline.

- **Ship small.** A hello-world should produce ~1KB of JavaScript. Zunk only emits scaffolding code for features the WASM actually imports — no dead code. The generated JS for a full game with canvas, input, and audio is still under 10KB.

- **Fast iteration.** `zunk run` compiles, bundles, serves, and live-reloads. File changes trigger a rebuild and the browser refreshes automatically. The goal is sub-second rebuild times for typical projects.

- **Production-ready output.** `zunk deploy` produces a `dist/` directory with content-hashed filenames, subresource integrity attributes, and preload hints — ready to drop onto any static file server (nginx, S3, Cloudflare Pages, etc.).

### The Vision

[CyberEther](https://github.com/luigifcruz/cyberether) is a case study for what WebAssembly, WebUSB, and WebGPU can achieve together: a GPU-accelerated signal processing framework with a flowgraph editor, real-time visualization, and cross-platform deployment -- all running in the browser via WebGPU without installation. It targets Vulkan, Metal, and WebGPU from one codebase.

A developer should be able to write something that ambitious and beautiful in 100% Zig, and zunk should handle the JS/HTML generation. The planned WebGPU UI framework (immediate-mode, Zig-native, likely extracted to its own repo) is designed to make this possible.

### Non-Goals (for now)

- Server-side rendering or SSR
- Package registry or dependency resolution (use Zig's build system)
- Framework opinions — zunk is a build tool + platform layer, not a UI framework (the WebGPU UI framework will be a separate project)
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
     ├── app-[hash].js           (generated)
     └── app-[hash].wasm         (compiled)
```

### Three Usage Paths

All three coexist in the same project. Use whichever fits your needs:

**Path 1 — Zero config (raw extern fns)**
```zig
// Just declare what you need. Zunk figures out the JS.
extern "env" fn canvas_fill_rect(ctx: i32, x: f32, y: f32, w: f32, h: f32) void;
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

### Web API Coverage (built-in resolution)

| Domain | Prefix | Examples |
|--------|--------|---------|
| Console | `console_*`, `log_*` | `console_log`, `log_i32`, `log_f64` |
| DOM | `dom_*` | `dom_set_text`, `dom_set_html`, `dom_query`, `dom_create_element` |
| Canvas 2D | `canvas_*`, `ctx2d_*`, `c2d_*` | `canvas_get_2d`, `c2d_fill_rect`, `c2d_arc` |
| WebGPU | `gpu_*` | `gpu_request_adapter`, `gpu_request_device`, `gpu_create_shader` |
| Web Audio | `audio_*` | `audio_init`, `audio_load`, `audio_play` |
| Input | `input_*` | `input_init`, `input_poll` |
| Fetch | `fetch_*` | `fetch_get`, `fetch_get_response_ptr` |
| WebSocket | `ws_*` | `ws_connect`, `ws_send`, `ws_close` |
| Storage | `storage_*` | `storage_set`, `storage_get`, `storage_remove` |
| Timers | — | `setTimeout`, `setInterval`, `requestAnimationFrame` |
| Clipboard | `clipboard_*` | `clipboard_write` |
| Performance | — | `performance_now`, `random`, `date_now` |

Any import not matching these patterns generates a stub with a diagnostic telling you exactly how to fix it.

### Lifecycle Protocol

Zunk detects these exports from your WASM and wires them up automatically:

| Export | Signature | When Called |
|--------|-----------|-------------|
| `init` | `fn () void` | Once after WASM + canvas ready |
| `frame` | `fn (dt: f32) void` | Every `requestAnimationFrame` |
| `resize` | `fn (w: u32, h: u32) void` | On window resize |
| `cleanup` | `fn () void` | On `beforeunload` |

If you export `frame`, zunk generates a render loop. If you don't, it doesn't. If you export `resize`, zunk generates a resize handler and a fullscreen canvas. Everything is adaptive.

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
├── src/
│   ├── zunk.zig                  # Root module — the single import for developers
│   ├── bind/
│   │   └── bind.zig              # Core binding system: Handle, CallbackFn, string exchange,
│   │                             #   callback table, comptime manifest serializer
│   ├── web/                      # Layer 2: Optional ergonomic Web API wrappers
│   │   ├── canvas.zig            #   Canvas 2D, DOM manipulation
│   │   ├── input.zig             #   Keyboard, mouse, touch, gamepad (polling model)
│   │   ├── audio.zig             #   Web Audio, spatial audio, AudioWorklet
│   │   └── app.zig               #   Lifecycle, timing, fetch, clipboard, window control
│   └── gen/                      # Build tool: WASM analysis + JS generation
│       ├── wasm_analyze.zig      #   Full WASM binary parser (imports, exports, types, names)
│       ├── js_resolve.zig        #   5-tier auto-resolution engine + Web API knowledge base
│       └── js_gen.zig            #   JS + HTML code generator (minimal, adaptive output)
├── examples/
│   └── bouncing-balls/
│       └── src/main.zig          # Complete example: pure Zig, no HTML, no JS
├── ARCHITECTURE.md               # Deep dive on design decisions
├── LICENSE
└── README.md
```

---

## Quick Start

### Install

```bash
git clone https://github.com/your-org/zunk.git
cd zunk
zig build -Doptimize=ReleaseSafe
# Binary at zig-out/bin/zunk
```

### Create a project

```bash
mkdir my-app && cd my-app
```

```zig
// src/main.zig — this is the ONLY file you need
extern "env" fn console_log(ptr: [*]const u8, len: u32) void;

fn log(msg: []const u8) void {
    console_log(msg.ptr, msg.len);
}

export fn init() void {
    log("Hello from Zig!");
}
```

### Run

```bash
zunk run
# → compiles, generates JS + HTML, serves at localhost:8080
```

### Deploy

```bash
zunk deploy
# → produces dist/ with hashed assets, ready for any static server
```

---

## Comparison

### vs wasm-bindgen (Rust)

wasm-bindgen is a post-processing tool that reads proc macro annotations from the WASM binary and generates JavaScript glue. It exists because Rust cannot introspect types at compile time.

Zunk takes a fundamentally different approach: it reads the WASM import table (which already contains function names and full type signatures) and resolves bindings from a knowledge base + inference engine. No annotations, no proc macros, no post-processing step. Zig's comptime means the binding definition is the code itself.

| | wasm-bindgen | zunk |
|---|---|---|
| Binding definition | Proc macro attributes | Naming convention + type signatures |
| JS generation | Post-process `.wasm` binary | Read `.wasm` imports during build |
| Build steps | `cargo build` → `wasm-bindgen` → bundler | `zunk run` (one command) |
| JS output size | ~50KB+ hello-world | ~1KB hello-world |
| String passing | Copies through JS heap | Direct linear memory reads |
| Input model | Per-event callbacks (async) | Polling (shared memory, game-friendly) |
| Requires | Rust nightly features | Stable Zig |

### vs Emscripten

Emscripten is a full C/C++ → WASM toolchain that reimplements libc, SDL, OpenGL, and other system libraries as JavaScript. It's comprehensive but heavyweight.

Zunk is minimal. It doesn't reimplement anything — it generates thin bridge code between your WASM exports/imports and native browser APIs. You get WebGPU, not a WebGL emulation of OpenGL. You get Web Audio, not an SDL_mixer shim.

### vs trunk (Rust)

trunk is the direct inspiration for zunk's build tool. It uses an HTML-driven asset pipeline (`<link data-trunk rel="rust" />`) to declare what to build. Zunk takes this further — the HTML is fully auto-generated based on what the WASM needs. No `index.html` template required.

---

## Status

The core architecture is implemented and functional (~2,400 lines of Zig). The WASM analyzer, 5-tier resolution engine, JS/HTML code generator, binding system, and Layer 2 web modules are all working. What remains is completing the build tool CLI (auto-compilation, dev server, deploy) and end-to-end validation.

See [docs/ROADMAP.md](docs/ROADMAP.md) for the full roadmap.
See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for a deep dive on design decisions.

---

## Design Principles

1. **Single source of truth.** The Zig code IS the specification. Both the WASM imports and the generated JavaScript are derived from what the developer writes. Nothing is duplicated.

2. **Explicit over implicit.** Following Zig's philosophy, there's no hidden magic. Every `extern fn` maps to exactly one JavaScript function. The resolution report tells you exactly what was generated and why.

3. **Minimal output.** The generated JavaScript includes only what's needed. No framework, no polyfills, no dead code. A console-only app gets ~1KB of JS.

4. **Progressive disclosure.** Start with raw `extern fn` declarations. Graduate to the Layer 2 ergonomic wrappers when you want nicer types. Use `bridge.js` when you need something custom. Each level adds convenience without requiring the previous one.

5. **Game-friendly.** The input system uses polling (shared memory written by JS each frame), not event callbacks. This is what game loops actually want — check `isKeyDown(.space)` in your frame function, not register an async callback.

---

## Contributing

The core modules are implemented. The highest-impact contributions right now:

1. **Auto-compilation** — making the CLI invoke `zig build` to compile user Zig source to WASM
2. **End-to-end validation** — compiling real projects through the full pipeline and verifying the generated JS runs correctly in a browser
3. **Dev server** — HTTP server + file watcher for the `zunk run` workflow
4. **WebGPU bindings** — the resolution engine has WebGPU prefix rules but generators need real implementations

---

## License

MIT OR Apache-2.0
