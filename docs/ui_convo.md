# UI Strategy for zunk

## The Question

How do we build UI in Zig + WASM where zunk generates the required HTML, CSS,
and JS? What are our options, and what path do we take?

---

## Options Considered

### Option 1: DOM Proxy (Thin Bridge)

Zig declares extern functions that map directly to DOM operations. Zunk
generates the JS bridge.

```
Zig code                          Generated JS
--------                          ------------
dom_createElement("div")    -->   document.createElement("div")
dom_setText(handle, ptr)    -->   el.textContent = str
dom_setStyle(handle, ...)   -->   el.style[k] = v
dom_appendChild(parent, c)  -->   parent.appendChild(child)
```

Uses the existing Handle table to track DOM elements as integer IDs. CSS
styling handled via `setStyle` / `setClass` extern calls.

**Pros:** Browser does layout, text rendering, accessibility, scrolling for
free. Simplest to implement. CSS is a mature styling system.

**Cons:** Chatty bridge (many small WASM<->JS calls). Not game-friendly. UI
logic split between Zig (structure) and CSS (styling). Feels un-Zig.


### Option 2: Declarative DOM (Batch Serialization)

Zig builds a UI tree in WASM linear memory using a compact binary format.
Each frame, JS reads the buffer and diffs against the real DOM.

```
Zig (in WASM memory)              Generated JS
----------------                  ------------
[TAG:div][ATTR:class,"btn"]  -->  reads buffer, builds/patches DOM
[CHILD][TAG:span][TEXT:"OK"]      only touches nodes that changed
[END][END]
```

Zig writes a flat byte stream describing the UI tree. JS reads it once per
frame and applies minimal DOM mutations.

**Pros:** Fewer WASM<->JS calls. Zig-side API can feel declarative and
ergonomic. Still gets browser layout and text for free.

**Cons:** More complex JS generator. DOM diffing logic in generated JS. Still
DOM-bound performance ceiling.


### Option 3: Canvas 2D Immediate Mode

Zig renders everything through Canvas 2D API calls. Zunk bridges the canvas
context methods.

```
Zig code                          Generated JS
--------                          ------------
canvas.fillRect(x,y,w,h)   -->   ctx.fillRect(x,y,w,h)
canvas.fillText(ptr,len,x,y) --> ctx.fillText(str,x,y)
canvas.setFillColor(r,g,b)  -->  ctx.fillStyle = ...
```

Immediate mode: rebuild UI every frame, no retained state. Layout engine lives
entirely in Zig. This is what zunk already partially supports with its canvas
module.

**Pros:** Simple bridge (already halfway there). Full control. Natural fit for
games and visualizations. Immediate mode is idiomatic for polling-based input.

**Cons:** You own layout, text measurement, scrolling, clipping. No native
text input. No accessibility. Text rendering quality depends on canvas.


### Option 4: WebGPU Rendered UI (the Iced / egui / GPUI Path)

Full GPU-accelerated UI pipeline. Zig builds geometry (quads, glyphs, curves),
submits via WebGPU.

```
Zig (render pipeline)             GPU
-----------------                 ---
Layout pass --> Geometry pass -->  Vertex/Fragment shaders
  |                |              render rounded rects,
  |                |              text (SDF atlas),
  |                |              shadows, blur
  Widget tree      Batched draw calls
```

Architecturally similar to Iced (Rust), egui (Rust), and GPUI (Zed's custom
framework). Core idea: widget tree -> layout -> render primitives -> GPU.

Text rendering via signed distance field (SDF) font atlases. Anti-aliased
vector shapes via shader math. Requires: layout engine, font rasterizer (or
SDF generator), input routing, hit testing.

**Pros:** Maximum performance. Resolution-independent. Beautiful rendering
(anti-aliased everything). Full creative control. True "no browser UI" story.

**Cons:** Most complex by far. Must solve text rendering, layout,
accessibility, scrolling, clipping, hit testing all yourself.


### Option 5: Hybrid (DOM + Canvas/WebGPU)

Use the right tool for each job. DOM for text-heavy/form UI, Canvas/WebGPU for
custom rendering.

```
+------------------------------------------+
|  DOM layer (z-index: above)              |
|  - text inputs, dropdowns, menus         |
|  - accessibility tree                    |
+------------------------------------------+
|  WebGPU layer (z-index: below)           |
|  - custom rendering, animations          |
|  - data viz, game world                  |
+------------------------------------------+
```

Zunk detects which APIs the WASM imports and generates both layers. DOM handles
what browsers are good at (text, forms, a11y). WebGPU handles what GPUs are
good at (rendering, animation).

**Pros:** Pragmatic. Get native text input and accessibility without
reimplementing them. GPU rendering where it matters.

**Cons:** Coordinating two rendering systems. Layout synchronization between
DOM and GPU layers. Two mental models.


### Summary Matrix

```
                    Complexity   Performance   Accessibility   Text Quality   Zunk Fit
                    ----------   -----------   -------------   ------------   --------
1. DOM Proxy        Low          Medium        Free            Native         Great
2. Declarative DOM  Medium       Medium        Free            Native         Good
3. Canvas 2D IM     Medium       Medium-High   Manual          Good           Great
4. WebGPU (GPU UI)  Very High    Highest       Manual          Manual (SDF)   Good
5. Hybrid           High         High          Partial Free    Mixed          Good
```

---

## Decision

### Phase A: Canvas 2D Immediate Mode (Option 3)

We start here. The canvas infrastructure already exists in zunk. The plan:

- Build an immediate-mode widget system on top of the existing
  `zunk.web.canvas` module
- Zig-native API: widgets are function calls, not objects
- Layout computed entirely in Zig (no CSS, no DOM)
- Text rendering via `canvas.fillText` (good enough for now)
- Input handled via the existing polling system (`zunk.web.input`)
- This gets us a usable UI system fast with minimal new bridge code

This phase is about learning. We build real UIs, discover what works, figure
out what an immediate-mode API should feel like in Zig, and identify the pain
points that only show up in practice.

**Exit criteria:** When the Canvas 2D backend becomes the bottleneck -- when we
need better text rendering (SDF), anti-aliased vector shapes, or complex
compositing that canvas cannot deliver efficiently.


#### Implementation (Phase A)

Built: `src/web/imgui.zig`, `src/web/render_backend.zig`, and canvas extensions.

**What exists:**

- `imgui.zig` -- Generic `Ui(Backend)` struct with egui-inspired immediate-mode
  API. Widgets: `label`, `button`, `slider`, `checkbox`, `separator`. Containers:
  `beginPanel`/`endPanel`, `beginHorizontal`/`endHorizontal`.
- `render_backend.zig` -- Comptime render backend interface (`validateBackend`)
  with `Canvas2DBackend` implementation wrapping `web/canvas.zig`.
- Canvas extensions: `measureText`, `clip`, `setTextBaseline` added to
  `canvas.zig` with corresponding JS resolutions in `js_resolve.zig`.

**Comptime backend pattern:**

```zig
// Any type satisfying the backend interface works:
//   drawFilledRect, drawStrokedRect, drawText, measureText,
//   setClipRect, clearClipRect, pushState, popState, setFont
pub fn Ui(comptime Backend: type) type { ... }

// Phase A uses Canvas 2D:
pub const CanvasUi = Ui(Canvas2DBackend);

// Phase B swap: implement GpuBackend, use Ui(GpuBackend) -- no API changes.
```

**Zero heap allocation.** Layout via fixed-size stack (max depth 16). ID system
uses FNV-1a hash with `"Label##unique"` disambiguator syntax. Dark theme with
customizable `Theme` struct.

**Recommended first exercise:** A standalone settings/dashboard demo -- a control
panel with sliders, checkboxes, buttons, and nested panels that exercises all
widgets without needing app logic. This becomes a living reference for the
widget API. After that, demo 9 (Spreadsheet from `more_demos.md`) is the ideal
stress test since it demands every widget type plus virtual scrolling.


### Phase B: Hard Pivot to GPU-Accelerated UI (Option 4)

When Canvas 2D hits its ceiling, we pivot to a full GPU-rendered UI. Not a
gradual migration -- a clean break (per our no-legacy philosophy).

**Inspiration:** Three frameworks inform this design:

1. **Iced** (Rust) -- Elm architecture (Model-View-Update), widget tree with
   layout and rendering separated, wgpu backend. Clean separation of concerns.
   Strong typing. Good mental model for declarative UI.

2. **egui** (Rust) -- Pure immediate mode. No retained widget tree. Every
   frame, you call `ui.button("Click me")` and it returns whether it was
   clicked. Incredibly simple API. Layout is implicit (vertical/horizontal
   stacking). Trade-off: harder to do complex layouts and animations.

3. **GPUI** (Zed editor) -- The most interesting one to study. Custom
   GPU-accelerated UI framework built for a production editor. Key ideas:
   - Entity system for reactive state management
   - GPU rendering via Metal/Vulkan shaders (rounded rects, shadows, text)
   - Text rendering via platform font rasterization + GPU atlas
   - Window management, input dispatch, focus handling
   - Designed for complex, interactive applications (not just widgets)

   **We want to do a deep dive on GPUI** to understand their architectural
   decisions, especially around: GPU rendering pipeline, text shaping and
   rasterization, layout system, entity/reactivity model, and how they handle
   the complexity of a real editor UI at 120fps.

**The widget API should be designed for backend-swappability.** Core operations
like "draw rect", "draw text", "measure text" should go through a render
backend trait (comptime interface in Zig) so the swap from Canvas 2D to WebGPU
is a backend change, not an API rewrite.


### Phase C: Unified GPU Abstraction (Vulkan + WebGPU)

The end goal: a single Zig codebase that targets GPU-accelerated rendering
across three platforms via two graphics APIs.

```
                    zunk GPU Abstraction Layer
                    -------------------------
                    Unified Zig API for:
                      - Pipeline creation
                      - Buffer management
                      - Render pass encoding
                      - Shader management
                      - Texture/sampler ops
                            |
              +-------------+-------------+
              |                           |
         Vulkan Backend              WebGPU Backend
         (via vulkan-zig             (via browser
          or raw Vk calls)            WebGPU API)
              |                           |
        +-----+-----+                    |
        |           |                    |
      Linux      Windows              Browser
```

**Target platforms:** Linux, Windows, Web. No macOS/Metal (Vulkan via
MoltenVK is an option if we ever care, but not a priority).

**Architectural inspiration:** wgpu (Rust) and Dawn (C++) both solve this
problem -- they present a WebGPU-like API and implement it on top of
Vulkan/Metal/D3D12. We take inspiration but scope it down: only Vulkan and
WebGPU backends, only the subset we actually need for UI rendering.

This means: one Zig repository, one build system, `zig build` produces native
executables (Vulkan) AND `zig build -Dtarget=wasm32-freestanding` produces
WASM (WebGPU). Same application code, same UI framework, two render backends.

**Key difference from wgpu/Dawn:** Those are general-purpose graphics
abstraction layers. Ours is purpose-built for UI rendering. We only need the
GPU features that UI demands: 2D geometry, text atlases, compositing,
clipping, maybe basic 3D for effects. This dramatically reduces scope.

---

## Research Backlog

- [ ] Deep dive on GPUI (Zed) architecture -- entity system, GPU pipeline,
      text rendering, layout engine
- [ ] Study Iced's widget trait system and how they separate layout from
      rendering
- [ ] Evaluate SDF font rendering approaches for WebGPU
- [x] Prototype a minimal comptime render backend interface in Zig
- [ ] Survey vulkan-zig bindings maturity and ergonomics
- [ ] Benchmark Canvas 2D fillText vs SDF atlas rendering for text-heavy UIs
