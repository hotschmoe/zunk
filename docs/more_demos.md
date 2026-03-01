# Demo Projects for Maturing zunk

Eleven projects designed to stress-test zunk's architecture, force new web API
bindings, and prove that "write only Zig, generate everything else" scales
beyond games and particles.

Each project lists the **web APIs it demands**, the **zunk modules it would
grow**, and the **hard problems** it surfaces.

---

## 1. ZanoGPT-Web -- Neural Inference on Every Backend

Port [zanogpt](https://github.com/hotschmoe/zanogpt) to the browser.
A character-level transformer that trains and generates names, running on
CPU (WASM SIMD), GPU (WebGPU compute), and NPU (WebNN) -- switchable at
runtime with a benchmark overlay comparing throughput across backends.

**Why it matters**: This is the zanogpt vision (CPU vs GPU vs NPU) realized
in pure Zig, in a browser, with zero JS. Nothing else in the ecosystem does
this.

```
[Zig Transformer] --+-- WASM SIMD (CPU fallback)
                    |
                    +-- WebGPU Compute (GPU path)
                    |
                    +-- WebNN Graph (NPU path)
                    |
                    +--> Canvas overlay: tokens/sec per backend
```

**Web APIs exercised**: WebNN (MLContext, GraphBuilder, operand layout),
WebGPU compute (already partial in zunk), WASM SIMD, Performance.now()
for timing.

**zunk growth**:
- `web/nn.zig` -- WebNN bindings (MLContext, Graph compilation, tensor I/O)
- `web/perf.zig` -- High-resolution timing utilities
- Proves zunk can host compute-heavy workloads, not just rendering
- Forces the resolver to handle WebNN's object-heavy API surface

**Hard problems**: WebNN is still shipping in browsers; feature-detection
and graceful fallback when an execution provider is missing. Tensor memory
layout negotiation between Zig structs and WebNN operands.

---

## 2. Video Player -- GPU-Accelerated Decode and Render

An MP4/WebM player that decodes frames via WebCodecs, uploads them as
WebGPU textures, and renders to canvas with shader-based color correction
and subtitle overlay.

```
File/URL --> Fetch stream --> WebCodecs VideoDecoder
                                    |
                              VideoFrame (GPU memory)
                                    |
                              WebGPU texture import
                                    |
                              Render pipeline (color grading fragment shader)
                                    |
                              Canvas (+ subtitle overlay pass)
```

**Web APIs exercised**: WebCodecs (VideoDecoder, AudioDecoder, EncodedVideoChunk),
Fetch streaming (ReadableStream), WebGPU texture-from-VideoFrame,
MediaSource Extensions (for seeking), Web Audio (playback sync).

**zunk growth**:
- `web/codec.zig` -- WebCodecs bindings (decoder config, frame lifecycle)
- Streaming fetch support in `web/asset.zig` (chunked/progressive loading)
- Texture import paths in `web/gpu.zig` (importExternalTexture)
- Forces the JS generator to handle object-returning async APIs

**Hard problems**: Frame timing synchronization between audio and video
decode pipelines. Seeking requires demuxing (container parsing in Zig or
delegating to MediaSource). GPU texture lifetime management across frames.

---

## 3. Photo Editor -- Canvas 2D + WebGPU Compute Filters

A raster image editor with layers, selections, and non-destructive filters.
Canvas 2D for the UI chrome (toolbars, layer panel), WebGPU compute shaders
for pixel operations (blur, sharpen, curves, histogram equalization).

```
Image file --> WASM memory (pixel buffer)
                    |
              +-----+------+
              |            |
        Canvas 2D UI   WebGPU Compute
        (tools, layers)  (filters, transforms)
              |            |
              +-----+------+
                    |
              Composited output --> Canvas display
              |
              Export (PNG via OffscreenCanvas.toBlob)
```

**Web APIs exercised**: File API (drag-and-drop, file picker), Canvas 2D
(compositing, pixel manipulation), WebGPU compute (image processing kernels),
OffscreenCanvas (export), Clipboard API (copy/paste images), Pointer Events
(pressure-sensitive drawing).

**zunk growth**:
- `web/file.zig` -- File picker and drag-drop bindings
- `web/clipboard.zig` -- Clipboard read/write for images and text
- Pointer Events pressure/tilt in `web/input.zig`
- Multi-buffer GPU compute dispatch patterns in `web/gpu.zig`
- Tests large memory scenarios (multi-megabyte images in WASM linear memory)

**Hard problems**: WASM linear memory is capped at 4GB; multi-layer high-res
images need careful memory management. Undo/redo with large buffers requires
a command pattern or copy-on-write scheme. Color space correctness
(sRGB vs linear) across Canvas 2D and WebGPU pipelines.

---

## 4. Blog CMS -- DOM-Heavy CRUD Application

A single-page content management system with a rich-text editor, post
listing, image uploads, and a preview mode. The anti-game: maximal DOM
interaction, minimal canvas.

This is deliberately outside zunk's comfort zone. It proves the framework
can handle "normal web apps", not just graphical demos.

```
Zig (app logic, routing, state)
    |
    +--> DOM manipulation (createElement, setAttribute, innerHTML)
    |
    +--> Fetch API (REST endpoints for CRUD)
    |
    +--> localStorage / IndexedDB (offline drafts)
    |
    +--> ContentEditable or custom text input handling
```

**Web APIs exercised**: DOM API (createElement, appendChild, event
listeners), Fetch (JSON payloads, multipart uploads), localStorage,
IndexedDB (via simple key-value wrapper), History API (client-side routing),
Intersection Observer (lazy-load images in post feed).

**zunk growth**:
- `web/dom.zig` -- DOM element creation, attribute/property setting, tree ops
- `web/fetch.zig` -- HTTP client with JSON and multipart support
- `web/storage.zig` -- localStorage and IndexedDB bindings
- `web/router.zig` -- History API pushState/popState wrapper
- Forces the JS resolver to handle callback-heavy APIs (event listeners,
  fetch .then chains, IndexedDB transactions)
- Proves zunk is not canvas-only

**Hard problems**: The JS bridge currently optimizes for
request-response-per-frame patterns. A DOM-heavy app fires many bridge calls
per user interaction. Batching DOM mutations (virtual DOM or mutation queue)
may be necessary to avoid call overhead. Rich text editing is notoriously
hard; a markdown-source + live-preview approach sidesteps ContentEditable
complexity.

---

## 5. Collaborative Whiteboard -- Real-Time Networking

A shared drawing canvas where multiple users draw simultaneously.
WebSocket for state sync, Canvas 2D for rendering, conflict-free replicated
data types (CRDTs) in Zig for merge logic.

```
User A (Zig)               Server (echo/relay)           User B (Zig)
    |                           |                            |
    +-- stroke event --------->|                            |
    |                          +-- broadcast -------------->|
    |                          |                            +-- apply + render
    |<-- stroke from B --------+                            |
    +-- apply + render         |                            |
```

**Web APIs exercised**: WebSocket (binary frames, not just text),
Canvas 2D (path rendering, pressure curves), Pointer Events (stylus support),
Blob/ArrayBuffer (binary serialization), Performance API (latency measurement).

**zunk growth**:
- `web/ws.zig` -- WebSocket client bindings (open, send binary, onmessage)
- Binary serialization patterns (Zig packed structs over the wire)
- Forces zunk to handle incoming async events (WebSocket messages)
  outside the frame loop -- this is a fundamental architecture challenge
  for the current polling model
- Tests multi-instance scenarios (two browser tabs, same app)

**Hard problems**: The polling input model works for local input but
network messages arrive asynchronously. zunk needs a message queue that
the frame loop drains, or an event hook system. CRDT implementation in
Zig is non-trivial but extremely valuable as a reusable library.

---

## 6. Music Tracker -- Deep Web Audio + MIDI

A step-sequencer / tracker-style music app. Grid-based UI for pattern
editing, real-time audio synthesis via AudioWorklet (Zig compiled to a
separate WASM module running on the audio thread), MIDI input for external
controllers.

```
MIDI Controller --> Web MIDI API --> Zig (note events)
                                        |
Pattern Grid (Canvas 2D) <-- Zig state --+
                                        |
                                   AudioWorklet
                                   (separate WASM)
                                        |
                                   AudioContext --> speakers
```

**Web APIs exercised**: Web Audio API (AudioContext, AudioWorklet,
oscillator nodes, gain, effects), Web MIDI API (input enumeration, note
on/off, CC messages), AudioWorklet + WASM (separate compilation target),
Canvas 2D (grid UI, waveform visualization).

**zunk growth**:
- `web/midi.zig` -- Web MIDI bindings (requestMIDIAccess, input ports)
- AudioWorklet support in `web/audio.zig` (currently only basic playback)
- Multi-WASM-module build pipeline (main module + audio worklet module)
- Sub-millisecond timing precision in the audio thread
- Forces `zunk build` to support compiling multiple WASM targets from
  one project

**Hard problems**: AudioWorklet runs on a separate thread with its own
WASM instance. zunk's build pipeline currently assumes one WASM binary;
this project forces multi-target builds. Audio thread cannot block or
allocate; the Zig code must be allocation-free in the hot path. MIDI
device enumeration is async and permission-gated.

---

## 7. 3D Model Viewer -- Full WebGPU Render Pipeline

Load and display 3D models (OBJ, glTF) with PBR materials, orbit camera,
and environment lighting. Pure rasterization pipeline -- no ray tracing,
but physically based shading.

```
glTF file --> Zig parser (in WASM)
                  |
            Vertex/Index buffers --> WebGPU
                  |
            Texture data --> WebGPU texture upload
                  |
            Render pipeline:
              Vertex shader (MVP transform, skinning)
              Fragment shader (PBR: metallic-roughness, IBL)
                  |
            Canvas output (orbit camera via mouse input)
```

**Web APIs exercised**: WebGPU (full render pipeline -- vertex buffers,
index buffers, uniform buffers, texture sampling, depth testing, MSAA),
Fetch (binary asset loading), Pointer Events (orbit/pan/zoom controls),
Resize Observer.

**zunk growth**:
- Full render pipeline helpers in `web/gpu.zig` (currently mostly compute)
- Uniform buffer management patterns
- Texture upload and sampler configuration
- glTF/OBJ parsing in pure Zig (reusable library opportunity)
- Tests large asset loading (multi-MB binary files)
- Proves WebGPU bindings work for graphics, not just compute

**Hard problems**: glTF is a complex format (scenes, nodes, meshes, skins,
animations, materials). Start with a static mesh subset and expand. PBR
shading requires environment maps (IBL) which means cubemap texture support.
Shader compilation errors are opaque from WASM -- good diagnostics matter.

---

## 8. Terminal Emulator -- Text Rendering and Escape Codes

A VT100-compatible terminal emulator running in the browser. WebSocket
connection to a backend shell, character grid rendered via Canvas 2D or
WebGPU, full keyboard input handling including modifier keys and special
sequences.

```
Keyboard --> Zig (input mapping, escape sequences)
                |
                +--> WebSocket (to pty backend)
                |
                +--> Terminal state machine (Zig)
                        |
                        +--> Character grid buffer
                        |
                        +--> Canvas 2D / WebGPU text render
```

**Web APIs exercised**: WebSocket (bidirectional binary stream), Canvas 2D
(text rendering, cursor blinking, selection highlighting), Keyboard Events
(full modifier handling, IME composition), Clipboard API (copy/paste),
Resize Observer (reflow on terminal resize).

**zunk growth**:
- VT100/xterm escape code parser in pure Zig (reusable library)
- Fast text rendering at scale (thousands of glyphs per frame)
- Complete keyboard handling in `web/input.zig` (IME, dead keys, AltGr)
- Selection and clipboard integration
- Tests sustained high-throughput WebSocket traffic (e.g., `cat` a large file)

**Hard problems**: Terminal emulation has decades of edge cases (escape code
dialects, Unicode width calculation, sixel graphics). Start with a VT100
subset sufficient for interactive shells. Text rendering performance at
terminal scale (80x24 minimum, ideally 200+ columns) needs glyph caching
or a texture atlas approach.

---

## 9. Spreadsheet -- Stress-Test for UI and Computation

A functional spreadsheet with formula evaluation, cell references,
basic charting, and CSV import/export. This project is a torture test for
zunk's UI capabilities and computational performance.

```
CSV Import --> Zig parser --> Cell grid (WASM memory)
                                  |
                            Formula engine
                            (expression parser, dependency graph,
                             topological evaluation)
                                  |
                            Canvas 2D render
                            (virtual scrolling, cell grid,
                             selection, editing overlay)
                                  |
                            Chart module
                            (bar, line, scatter via Canvas 2D or WebGPU)
```

**Web APIs exercised**: Canvas 2D (large grid rendering, text measurement,
virtual scrolling), File API (CSV import), Blob + download (CSV export),
Clipboard API (paste tabular data), Keyboard Events (cell navigation,
formula input), Pointer Events (cell selection, drag-fill).

**zunk growth**:
- Virtual scrolling patterns (render only visible cells)
- Text input handling (zunk has no text input story today)
- Expression parser and evaluator in Zig (comptime tokenizer opportunity)
- Dependency graph and topological sort for cell recalculation
- Tests rendering performance with large datasets (10k+ cells visible)

**Hard problems**: Text input in a canvas-only app requires an invisible
DOM textarea or IME bridge -- this is the single hardest UX problem for
canvas-based apps and zunk must solve it eventually. Virtual scrolling at
60fps with formula recalculation demands careful frame budgeting. Circular
reference detection in the dependency graph.

---

## 10. WebRTC Video Chat -- Peer-to-Peer Media

A two-party video chat application. Camera/microphone capture, WebRTC
peer connection, and video rendering to canvas. Minimal UI: local preview,
remote video, mute/hangup controls.

```
getUserMedia --> local MediaStream
                     |
                +----+----+
                |         |
          Local preview   RTCPeerConnection
          (Canvas 2D)     (SDP offer/answer via signaling WebSocket)
                          |
                    Remote MediaStream
                          |
                    Canvas 2D render (or VideoFrame + WebGPU)
```

**Web APIs exercised**: WebRTC (RTCPeerConnection, SDP negotiation, ICE
candidates), MediaDevices (getUserMedia, device enumeration), MediaStream,
WebSocket (signaling channel), Canvas 2D (video frame rendering),
Permissions API (camera/mic access).

**zunk growth**:
- `web/rtc.zig` -- WebRTC peer connection bindings
- `web/media.zig` -- MediaDevices and MediaStream bindings
- `web/permission.zig` -- Permissions API query and request
- Async negotiation flow (SDP offer/answer is multi-step and async)
- Forces the bridge to handle complex object passing (MediaStream,
  RTCSessionDescription are JS objects that must stay on the JS side
  as handles)

**Hard problems**: WebRTC's API surface is enormous. Scope to a direct
1:1 call with a known signaling server (no SRTP, no TURN relay, no
data channels in v1). SDP is an opaque text blob best left on the JS side
-- the Zig code orchestrates but does not parse SDP. ICE candidate
trickling requires async event handling.

---

## 11. Parallel Raytracer -- Multi-Threaded WASM via Web Workers

A progressive path tracer that distributes tile rendering across multiple
Web Workers, each running the same WASM module against shared linear memory.
The main thread composites tiles to canvas in real-time, with a UI showing
per-worker throughput and total speedup vs single-threaded baseline.

This is the hardest systems-level demo on the list. It forces zunk to solve
WASM multithreading end-to-end, which no pure-Zig browser framework has
done.

### How WASM multithreading actually works

There is no `std.Thread` for `wasm32-freestanding`. Browsers do not let
WASM modules spawn threads directly. Instead, multithreading is built from
three browser primitives:

```
1. SharedArrayBuffer     -- backing store for WebAssembly.Memory({shared: true})
2. Web Workers           -- OS threads, each instantiates the same WASM module
3. Atomics               -- wait/notify/CAS on shared memory (WASM atomic instrs)
```

The architecture for this demo:

```
Main thread (Zig)                        Worker threads (Zig)
  |                                        |
  +-- init(): set up scene in shared mem   |
  |                                        |
  +-- [zunk JS] spawn N Web Workers ------>+-- each worker instantiates
  |              pass SharedArrayBuffer    |   same .wasm with shared memory
  |                                        |
  +-- write tile assignments to      ----->+-- worker reads assignment via
  |   shared memory (atomic store)         |   atomic load
  |                                        |
  |                                        +-- render tile: ray-scene intersect,
  |                                        |   write pixels to shared framebuffer
  |                                        |
  +-- frame(): read shared framebuffer <---+-- atomic flag: tile complete
  |   blit completed tiles to canvas       |
  |                                        |
  +-- UI: worker count slider,             |
  |   tiles/sec, linear speedup graph      |
  |                                        |
  +-- cleanup(): signal workers to exit    |
```

### What the Zig developer writes

The key insight: since zunk generates all JS, it can generate the Web Worker
scaffolding automatically. The Zig developer writes:

- A `render_tile(tile_id: u32, shared_buf: [*]u8) void` function, exported
- Scene data structures in shared memory (positions, materials, BVH)
- The main thread `frame()` composites finished tiles

zunk's code generator detects the threading pattern (shared memory flag +
worker export convention) and emits the Worker instantiation, message
passing, and SharedArrayBuffer plumbing. The developer never writes a line
of JavaScript worker code.

### What makes this hard in Zig + wasm32-freestanding

**No std.Thread**: Zig's standard library thread support does not exist for
`wasm32-freestanding`. Thread creation happens on the JS side (Web Workers).
The Zig code only sees shared memory and atomic operations.

**Stack isolation**: Each Web Worker instantiates a separate WASM instance
but shares the same linear memory. Each worker needs its own stack region.
zunk must partition the linear memory: one stack per worker, plus a shared
heap region. This is what Emscripten does internally, but zunk must
implement it from scratch since we target freestanding, not emscripten.

```
Linear memory layout (shared):
+------------------+------------------+-----+------------------+-----------+
| Main stack (64K) | Worker 0 (64K)   | ... | Worker N (64K)   | Shared    |
|                  |                  |     |                  | heap/data |
+------------------+------------------+-----+------------------+-----------+
0              65536            131072                     (N+1)*65536
```

**No allocator**: The standard WASM page allocator is not thread-safe.
Shared heap access needs a mutex built from `Atomics.wait` / `Atomics.notify`
(WASM `memory.atomic.wait32` / `memory.atomic.notify`). For a raytracer,
pre-allocating all buffers avoids runtime allocation entirely -- the
practical path.

**Build flags**: The WASM binary must be compiled with shared memory enabled.
In Zig's build system: `lib.shared_memory = true`. This produces a module
with `(memory (shared ...))` in the WASM binary. The Zig compiler also needs
bulk-memory and atomics features enabled for the target.

**Required HTTP headers**: SharedArrayBuffer requires cross-origin isolation.
zunk's dev server (`gen/serve.zig`) must serve:
```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

**Web APIs exercised**: Web Workers (spawn, postMessage, terminate),
SharedArrayBuffer, Atomics (wait, notify, store, load, compareExchange),
WebAssembly.Memory({shared: true}), Canvas 2D (ImageData for tile blitting),
Performance API (per-worker timing).

**zunk growth**:
- `web/worker.zig` -- worker-side entry point and shared memory access helpers
- Thread-aware build pipeline: `shared_memory = true`, atomics target features
- JS generator: emit Worker creation, SharedArrayBuffer passing, and
  lifecycle management
- Memory partitioning: automatic stack-per-worker layout in linear memory
- Atomic primitives in Zig: mutex, barrier, atomic counters over shared mem
- COOP/COEP headers in `gen/serve.zig`
- Build report: "N worker exports detected, generating threaded scaffold"

**Hard problems**: Determining the right number of workers
(`navigator.hardwareConcurrency` from JS, passed to WASM at init). Graceful
degradation when SharedArrayBuffer is unavailable (Safari with COOP/COEP
issues, older browsers) -- fall back to single-threaded rendering. Debugging
is painful: browser devtools for Workers + WASM is sparse. Memory ordering
in WASM only offers unordered and sequentially consistent (no
acquire/release), which may leave performance on the table for expert
lock-free patterns.

**Why a raytracer**: Embarrassingly parallel, visually dramatic (watch tiles
fill in), trivially benchmarkable (tiles/sec scales linearly with worker
count on multi-core machines), and the scene data + framebuffer naturally
map to shared memory without complex synchronization.

---

## Build Order Recommendation

Sequenced by dependency and incremental value to the framework:

```
Phase A (core web API expansion):
  [4] Blog CMS ............. DOM, Fetch, Storage -- proves zunk is not canvas-only
  [5] Whiteboard ........... WebSocket, async events -- solves the polling gap

Phase B (media and GPU depth):
  [2] Video Player ......... WebCodecs, streaming, GPU textures
  [3] Photo Editor ......... File API, compute shaders, large memory
  [7] 3D Model Viewer ...... Full WebGPU render pipeline

Phase C (advanced APIs and threading):
  [6] Music Tracker ........ AudioWorklet, MIDI, multi-WASM builds
  [8] Terminal Emulator .... Text rendering, keyboard depth, sustained I/O
  [11] Parallel Raytracer .. Web Workers, SharedArrayBuffer, WASM atomics

Phase D (frontier):
  [1] ZanoGPT-Web .......... WebNN, cross-backend ML inference
  [9] Spreadsheet .......... Text input, virtual scroll, formula engine
  [10] WebRTC Chat ......... Peer connections, media capture

Each phase builds on bindings and patterns established by the previous one.
Demo 11 (raytracer) is in Phase C because it benefits from the multi-WASM
patterns established by the music tracker (demo 6), and its shared memory
plumbing feeds directly into demo 1 (ZanoGPT) where CPU-side parallelism
via workers would complement GPU/NPU paths.
```

---

## What "Done" Looks Like

For each demo:

1. Compiles with `zunk build` from a single `src/main.zig`
2. Runs with `zunk run` -- no manual JS or HTML
3. Ships under 200KB of generated JS (excluding WASM)
4. Works in Chrome and Firefox (Safari where API support exists)
5. Includes a `README.md` explaining what it demonstrates
6. Exercises at least one web API that no previous demo touched
