# zunk Architecture: Why Zig Doesn't Need wasm-bindgen

## The Problem

When building web apps in Zig compiled to WASM, you face the **paired-file problem**: every browser API you want to call requires writing both a `.zig` file (with `extern fn` declarations) AND a `.js` file (with the actual browser API calls). These must be kept perfectly in sync — matching function names, parameter counts, types, and calling conventions. Isaac's `zig-wasm-ffi` repo demonstrates this pain: matched pairs for canvas, audio, input, etc.

Rust solved this with `wasm-bindgen` — a tool that post-processes `.wasm` binaries, reads custom attributes from Rust proc macros, and generates JavaScript glue. But wasm-bindgen is fundamentally a *hack around Rust's limitations*:

1. Rust proc macros can annotate code but can't introspect types at compile time
2. The WASM binary must be post-processed by an external tool
3. The generated JS is massive (wasm-bindgen's output for a hello-world is ~50KB of JS)
4. The developer must run `wasm-bindgen` as a separate build step

## Why Zig Is Different

Zig has `comptime`. This changes everything.

In Zig, you can:
- Reflect on types at compile time
- Generate code (including data) based on type information
- Embed arbitrary data into the binary via comptime-computed arrays
- Create `extern fn` declarations from comptime-known descriptors

This means the **binding definition IS the implementation**. There's no need for a post-processing step.

## The zunk Architecture

```
SINGLE SOURCE OF TRUTH (Zig comptime)
         │
         ├──→ extern fn declarations (Zig side, compiled into WASM)
         │
         └──→ binding manifest (embedded in WASM custom section)
                     │
                     └──→ zunk reads this → generates matching JS
```

### Layer 1: Binding Descriptors (`src/bind/bind.zig`)

The core abstraction. A binding is described as a `FuncDesc`:

```zig
const desc = bind.func(
    "getContext",          // function name
    "canvas",             // JS module/namespace
    &.{                   // parameters
        bind.param("selector", .string),
    },
    bind.ret(.handle),    // return type
    .dom,                 // JS generation hint
);
```

This single definition tells both sides everything:
- **Zig side**: generates `extern "env" fn zunk_canvas_getContext(ptr: [*]const u8, len: u32) i32`
- **JS side**: zunk generates `env.zunk_canvas_getContext = (ptr, len) => { ... }`

### Layer 2: Web API Modules (`src/web/*.zig`)

Pre-built ergonomic wrappers for common browser APIs:
- `canvas.zig` — Canvas 2D, DOM manipulation
- `input.zig` — Keyboard, mouse, touch, gamepad (polling model)
- `audio.zig` — Web Audio API, spatial audio, AudioWorklet
- `app.zig` — Lifecycle, timing, window control, fetch

These declare the `extern fn`s and wrap them in nice Zig APIs. A developer never sees the raw extern declarations.

### Layer 3: zunk Build Tool

Reads the compiled `.wasm`, finds `extern "env"` imports, and generates JavaScript implementations. It uses a combination of:

1. **Name convention**: `zunk_canvas_*` → Canvas API, `zunk_audio_*` → Audio API, etc.
2. **Binding manifest** (if present): A WASM custom section with full type information
3. **Built-in templates**: For known Web APIs (WebGPU, Canvas, Audio, Input)
4. **Library-provided JS** (escape hatch): If a Zig dependency ships a `bridge.js`

## Memory Model

WASM↔JS communication uses these patterns:

### Scalars (i32, f32, etc.)
Pass directly as WASM function params/returns. Zero overhead.

### Strings
Two approaches depending on direction:

**Zig → JS** (e.g., setting element text):
```
Zig: extern fn zunk_dom_set_text(sel_ptr, sel_len, txt_ptr, txt_len)
```
JS reads from WASM linear memory using the pointer and length.

**JS → Zig** (e.g., reading clipboard):
Uses the shared exchange buffer. JS writes to it, returns the length. Zig reads.

### Opaque Handles
JS objects (Canvas, AudioContext, GPUDevice) can't be passed as WASM values. Instead:
- JS maintains a `handleTable: Map<number, any>`
- When creating an object, JS stores it and returns the integer ID
- Zig stores it as `Handle` (an `enum(i32)`)
- When calling methods, Zig passes the handle ID back to JS

### Structs (InputState)
For high-frequency data like input state, we use a **shared memory region**:
- Zig allocates a struct in its linear memory
- Zig exports the pointer via `__zunk_input_state_ptr`
- JS writes directly into WASM memory each frame
- Zero marshalling overhead — just raw memory writes

## Lifecycle Protocol

zunk expects the WASM module to export these functions:

| Export | Signature | When Called |
|--------|-----------|-------------|
| `init` | `fn() void` | Once, after WASM + WebGPU/Canvas ready |
| `frame` | `fn(dt: f32) void` | Every `requestAnimationFrame` |
| `resize` | `fn(w: u32, h: u32) void` | On window/canvas resize |
| `cleanup` | `fn() void` | On `beforeunload` (optional) |

The generated JS creates the render loop:

```javascript
let lastTime = 0;
function loop(time) {
    const dt = (time - lastTime) / 1000;
    lastTime = time;
    exports.frame(dt);
    requestAnimationFrame(loop);
}
exports.init();
requestAnimationFrame(loop);
```

## Comparison with wasm-bindgen

| Aspect | wasm-bindgen (Rust) | zunk (Zig) |
|--------|-------------------|------------|
| How bindings are defined | Proc macro attributes | Comptime descriptors + extern fn |
| When JS is generated | Post-processing step on .wasm | During zunk build (reads .wasm imports) |
| JS output size | ~50KB+ for hello-world | ~5KB for hello-world |
| Complex types | Serde-based serialization | Shared memory + handles |
| String passing | Copies through JS heap | Direct linear memory reads |
| Callback model | Complex closure wrapping | Simple callback table (id → fn ptr) |
| Build steps | cargo build → wasm-bindgen → bundler | zunk run (one step) |
| Input handling | Per-event callbacks (async) | Polling model (sync, game-friendly) |

## The Developer Experience

A developer building a web app with zunk:

1. Creates a Zig project with `src/main.zig`
2. Imports `@import("zunk")` for web APIs
3. Exports `init`, `frame`, `resize`
4. Runs `zunk run` — everything just works

No HTML template needed. No JavaScript. No config file (optional Zunk.toml for customization).

```
my-app/
├── src/
│   └── main.zig      ← The ONLY file the developer writes
├── assets/            ← Optional: images, sounds, fonts
│   ├── explosion.wav
│   └── spritesheet.png
└── build.zig          ← Standard zig build (optional)
```

`zunk run` produces:
```
dist/
├── index.html         ← Generated: canvas, meta tags, script loader
├── app-[hash].js      ← Generated: all web API implementations
├── app-[hash].wasm    ← Compiled from src/main.zig
└── assets/            ← Copied from assets/
    ├── explosion.wav
    └── spritesheet.png
```

## Auto-Resolution: How zunk Generates JS Without Descriptors

The breakthrough feature. When a developer writes:

```zig
extern "env" fn canvas_fill_rect(ctx: i32, x: f32, y: f32, w: f32, h: f32) void;
extern "env" fn performance_now() f64;
extern "env" fn my_custom_thing(a: i32, b: i32) i32;
```

Zunk reads the compiled `.wasm` import section and resolves each one through a 5-tier system:

### Tier 1: Exact Match
The import name matches a known Web API function verbatim.
`performance_now` → `return performance.now();` (**exact** confidence)

### Tier 2: Prefix/Namespace Match
The name starts with a known prefix (`canvas_`, `audio_`, `dom_`, `gpu_`, etc.).
`canvas_fill_rect` → `H.get(arguments[0]).fillRect(...)` (**exact** confidence)

This works for both `zunk_` prefixed names (from Layer 2 modules) and raw Web API names. The developer can use either convention.

### Tier 3: Signature Inference
The WASM type signature + function name keywords combine to infer behavior:
- `(i32, i32) → void` + name contains "log" → string console output (**high** confidence)
- `(i32, i32) → i32` + name contains "query" → DOM query returning handle (**high** confidence)
- `() → f64` + name contains "time" → `performance.now()` (**high** confidence)
- `(i32) → void` + name contains "free" → handle release (**high** confidence)

### Tier 4: Parameter Name Inference
If the WASM was built in debug mode, the name section contains parameter names:
- Params named `selector_ptr, selector_len, text_ptr, text_len` → DOM text setter (**medium** confidence)
- Params named `url_ptr, url_len` + name contains "fetch" → network request (**medium** confidence)

### Tier 5: Stub Generation
When nothing matches, zunk generates a warning stub:
```javascript
my_custom_thing() { console.warn('[zunk] unresolved: my_custom_thing(i32, i32) → i32'); return 0; }
```
And the build report tells you exactly what's unresolved and how to fix it.

### Resolution Report
Every build produces a diagnostic report:
```
=== zunk binding resolution report ===

Total imports: 23
Total exports: 4
Unresolved (stubs): 1

⚠  UNRESOLVED IMPORTS:
   • env.my_custom_thing (i32, i32) → i32

Resolved bindings by category:
  canvas2d: 12
  input: 5
  console: 3
  performance: 2

Lifecycle exports detected:
  init: ✓
  frame: ✓
  resize: ✓
  cleanup: ✗
```

### The Escape Hatches
For unresolved imports, the developer has three options (in order of preference):

1. **Rename** to use a zunk convention — fastest fix
2. **Provide a `bridge.js`** — zunk auto-includes it in the generated output
3. **Use Layer 2 modules** — `@import("zunk").web.*` for ergonomic typed APIs

## Extending with Custom Bindings

If your library needs a browser API that zunk doesn't have built-in (e.g., WebRTC, WebXR), you have two options:

### Option A: Declare extern fns + ship a bridge.js

Your library ships a small JS file alongside the Zig code:

```
my-webrtc-lib/
├── src/webrtc.zig     ← extern fn declarations + Zig wrappers
├── js/bridge.js       ← JS implementations of those externs
└── build.zig
```

Zunk auto-detects `js/bridge.js` and includes it in the generated output.

### Option B: Use the binding descriptor system

Define your bindings using `bind.func()`, and zunk generates the JS from the manifest. This only works for APIs that fit zunk's generation templates.

## Future: The Full Stack

The end goal for your ecosystem:

```
Developer's Zig App
    │
    ├── imports "zunk" for web platform APIs
    ├── imports "your-webgpu-ui-lib" for GPU rendering
    ├── imports "your-ecs" or whatever else
    │
    └── zunk run / zunk deploy
            │
            ├── Compiles everything to WASM
            ├── Generates HTML + JS (from binding manifests)
            ├── Bundles assets
            ├── Content-hashes for cache busting
            └── Serves with live reload / produces dist/
```

The developer writes pure Zig. Everything else is generated.
