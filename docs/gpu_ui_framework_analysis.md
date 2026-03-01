# GPU-Accelerated UI for zunk: GPUI vs Iced vs Raw wgpu

Deep dive analysis for deciding the architectural direction of zunk's UI framework.

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [GPUI Deep Dive](#gpui-deep-dive)
3. [Iced Deep Dive](#iced-deep-dive)
4. [Raw wgpu / WebGPU Path](#raw-wgpu--webgpu-path)
5. [Zig-Idiomatic Analysis](#zig-idiomatic-analysis)
6. [Head-to-Head Comparison](#head-to-head-comparison)
7. [Recommendation for zunk](#recommendation-for-zunk)
8. [Evolution Roadmap](#evolution-roadmap)

---

## Executive Summary

After deep-diving GPUI (Zed), Iced (Elm-architecture), and the raw wgpu/WebGPU
ecosystem, the recommendation is: **neither a pure GPUI clone nor a pure Iced
clone**. Instead, zunk should take a third path that cherry-picks the best ideas
from each, adapted to Zig's strengths and zunk's WASM-first constraint.

```
  Take from GPUI:                  Take from Iced:
  - SDF primitive rendering        - TEA-inspired state/message loop
  - Instanced draw call batching   - Constraint-based layout (Limits)
  - Closed-form shadows            - Two-phase prepare/render split
  - Arena-per-frame allocation     - Per-capability renderer interfaces
  - Handle-based entity refs       - Reactive rendering / damage tracking

  Take from neither (Zig-native):
  - Comptime interface checking (no traits, no vtables for hot path)
  - Tagged unions for widget types (closed set, no dynamic dispatch)
  - Flat arena layout (cache-friendly, no tree allocations)
  - WGSL-only shaders (single target, no cross-compilation)
  - Polling-based input (already have this -- keep it)
```

**Key insight**: GPUI solves problems we do not have (Rust borrow checker
gymnastics) and creates problems we cannot afford (OS-native text APIs
unavailable in WASM). Iced's architecture maps more cleanly to Zig but its
Rust-specific patterns (trait objects, closures, lifetime-parameterized trees)
need fundamental rethinking. The right answer is a purpose-built Zig framework
that renders via WebGPU using a small set of specialized shaders.

---

## GPUI Deep Dive

### Architecture

GPUI is a hybrid immediate/retained mode GPU-accelerated UI framework. Three
conceptual registers:

```
Register 1: Entity-Based State
  App struct owns ALL state in a single EntityMap (SlotMap).
  Entities are opaque handles (Entity<T>). State only accessible
  through App context. "Lease pattern" for mutation: entity state
  is temporarily removed from the map during update callbacks.

Register 2: Declarative Views
  Views implement Render trait. Each frame, render() produces an
  element tree styled via Tailwind-inspired API. Conceptually
  immediate mode -- rebuilt every frame.

Register 3: Imperative Elements
  Low-level building blocks with two-phase lifecycle:
  prepaint (layout) and paint (GPU submission).
```

### Rendering Pipeline

GPUI renders UI like a video game. Custom shaders for each primitive type:

```
Primitives:
  1. Quads     -- rounded rects, borders, backgrounds (SDF in fragment shader)
  2. Shadows   -- closed-form Gaussian (Evan Wallace / Figma technique)
  3. MonoSprites -- text glyphs (alpha-only, color applied in shader)
  4. PolySprites -- emoji, images (full RGBA)
  5. Paths     -- arbitrary vector paths (MSAA)
  6. Underlines -- text decorations
```

The frame lifecycle:

```
cx.notify() --> Effect Queue --> WindowInvalidator marks dirty
  |
  v (next vsync)
PREPAINT: render() called on root, element tree built, Taffy layout computed
  |
  v
PAINT: elements emit primitives via cx.paint_quad(), collected into Scene
  |
  v
GPU SUBMISSION: scene sorted by layer, instanced draw calls per primitive type
```

#### SDF Rectangle Rendering

The vertex shader sets up two triangles as a bounding box. The fragment shader
computes signed distance to the rectangle edge:

```
distance = length(max(abs(position - center) - half_size + radius, 0.0)) - radius
```

This distance drives fill (inside = distance <= 0), anti-aliasing (smooth
transition near 0), and per-side borders.

#### Shadow Rendering

GPUI uses Evan Wallace's closed-form technique (the Figma co-founder). A 2D
drop shadow decomposes as the product of two perpendicular 1D blurred boxes.
Each has a closed-form solution using the error function (erf). Single-pass,
constant-time per-pixel -- no texture sampling loops.

#### Draw Call Batching

Within each layer, primitives sorted by type and drawn with instanced rendering:
all shadows in one draw call, all quads in one, all glyphs in one. Z-ordering
solved by pushing Layers (stacking contexts) -- painter's algorithm.

### Layout

Uses **Taffy** (Rust flexbox/grid implementation). Zed maintains their own fork.
Each element calls `request_layout()` during prepaint, Taffy computes all
positions in one pass. Tailwind-inspired style API (`.flex()`, `.w_full()`,
`.gap_2()`).

Limitation discovered: Taffy works well for editor-style layouts but struggled
with form-based interfaces (Settings UI required extending GPUI with tab groups
and React-hooks-style `use_state`).

### Entity/Reactivity Model

The `App` struct owns all entities in a `SlotMap`. The effect queue prevents
reentrancy: `cx.notify()` and `cx.emit()` push effects to a queue, flushed at
the end of the outermost `App::update()`. This eliminates recursive listener
bugs (learned from Atom's JavaScript event system).

Observer pattern: `cx.observe(&entity, callback)` fires when entity calls
`cx.notify()`. Multiple notify calls within one update coalesce into a single
redraw. **Whole-window invalidation** -- no partial dirty regions.

### Text Rendering

Delegates to OS APIs entirely:
- macOS: CoreText
- Windows: DirectWrite
- Linux: HarfBuzz + FreeType

Glyphs rasterized on CPU (alpha-only), packed into GPU texture atlas via bin
packing. Up to 16 subpixel variants per glyph. Single instanced draw call for
all glyphs per layer.

**Does NOT use SDF for text.** Rationale: code editor text is static (no
scaling/rotation), OS rasterizers produce best native appearance.

### Input Dispatch

Two-phase capture/bubble model (browser DOM-inspired). Mouse events use hit
testing against rectangular Hitbox regions. Keyboard events dispatch through
focus path via Action system (keystroke -> keymap lookup -> action dispatch).

### Critical Trade-offs for zunk

```
GPUI Strength                          zunk Relevance
--------------                         --------------
Entity system (solves Rust borrows)    NOT NEEDED (Zig has no borrow checker)
OS-native text (platform fidelity)     BLOCKED (no OS APIs in WASM)
Metal/Vulkan/D3D backends             NARROWER (WebGPU only for browser)
Whole-window invalidation             RISKY (WASM GPU bandwidth limited)
Custom shaders per primitive           EXCELLENT FIT (small, focused shader set)
Arena-per-frame allocation            EXCELLENT FIT (Zig arenas are first-class)
Instanced batching                    EXCELLENT FIT (minimizes WASM<->JS calls)
```

**Web/WASM is structurally blocked in GPUI.** The gpui-ce maintainer noted the
crate needs to split into core/web/native as "web needs a new executor and
native has deps that won't play nice with wasm." This is not a missing backend
-- it is a fundamental architecture issue. We should not try to port GPUI to
WASM.

---

## Iced Deep Dive

### Architecture: The Elm Architecture (TEA)

```
State (struct)  -->  view(&self)  -->  Widget Tree  -->  Screen
     ^                                                     |
     |                                                     |
     +--- update(&mut self, message) <--- Message <--------+
                                         (tagged union)
```

Four pillars:
1. **State**: A user-defined struct. All application data.
2. **Messages**: A user-defined enum (tagged union in Zig). Every possible event.
3. **Update**: `fn update(&mut self, message: Message)` -- the ONLY place state
   mutates. Returns `Task<Message>` for async side effects.
4. **View**: `fn view(&self) -> Element<Message>` -- pure function from state to
   widget tree. No mutation. Called after every update.

### Widget System

The `Widget` trait has three required methods:

```
size()   -- declares intrinsic sizing (Fill, Shrink, Fixed)
layout() -- computes layout node given constraint Limits
draw()   -- issues draw commands to renderer
```

Plus optional: `tag()`, `state()`, `children()`, `diff()`, `update()`,
`mouse_interaction()`, `overlay()`.

Three parallel trees maintained:
1. Widget tree (Element tree from view(), rebuilt each frame)
2. State tree (Tree, persisted, holds scroll pos / text cursor / etc.)
3. Layout tree (Node tree, computed during layout pass)

`diff()` reconciles new widget tree with old state tree -- analogous to React's
virtual DOM diffing.

### Layout Engine

Iced deliberately does NOT use a standalone layout engine (no Taffy, no
Morphorm). Each widget implements its own `layout()`. Originally used the
`stretch` crate (CSS Flexbox) but dropped it -- reasons:

- Flexbox is hard to use properly (properties tied to parent flex-direction)
- Forced uniformity (every node as flex node, even trivial ones)
- Simpler custom system suffices

The replacement (inspired by Druid/Flutter): top-down constraint propagation
with bottom-up size resolution.

```
Limits: {min: Size, max: Size}

Parent passes constraints down.
Child computes size within constraints, returns Node.
Parent positions children, returns aggregate Node.
```

Key types:
- **Limits** -- min/max constraints, methods: width(Length), height(Length),
  resolve()
- **Node** -- layout output: Size + Vec<Node> children
- **Length** -- Fill, FillPortion(u16), Shrink, Fixed(f32)

Row/Column delegate to internal `flex` module with Axis enum. Algorithm:
measure Shrink children first, distribute remaining space to Fill/FillPortion
proportionally, position along main axis with spacing.

### Rendering Backend

Three-layer architecture:

```
iced_renderer (facade)
  |
  +-- iced_wgpu (GPU: Vulkan/Metal/DX12/OpenGL/WebGPU via wgpu)
  +-- iced_tiny_skia (CPU: software rasterizer fallback)
  |
  +-- iced_graphics (shared: Layer, Compositor trait)
```

Backend selection is compile-time. Four specialized GPU pipelines:

```
Pipeline     Purpose                    Details
--------     -------                    -------
Quad         Rectangles                 Rounded corners, borders, gradients, shadows
Text         Glyphs                     cosmic-text shaping, glyphon atlas rendering
Triangle     Custom meshes              Vertex/index buffers, MSAA
Image        Textures                   Atlas management
```

Two-phase prepare/render split: `prepare()` uploads vertex/glyph/texture data to
GPU, `render()` issues actual draw calls. Minimal CPU work in render phase.

### Renderer Trait Design

Compositional, not monolithic. Per-capability traits:

```
text::Renderer    -- can measure and draw text
quad::Renderer    -- can fill quads (fill_quad)
image::Renderer   -- can draw raster images
svg::Renderer     -- can draw SVG images
```

A Text widget only requires `Renderer: text::Renderer`. A Button requires both
`text::Renderer + quad::Renderer`. The application's renderer must satisfy all
constraints from all widgets used.

Base `Renderer` trait: `with_layer()`, `with_translation()`, `fill_quad()`,
`clear()`.

### Text Rendering Stack

```
cosmic-text (shaping via rustybuzz, layout, font matching via fontdb)
    |
    v
glyphon (glyph atlas packing via etagere, wgpu rendering)
    |
    v
iced_wgpu text pipeline
```

cosmic-text provides: complex script shaping (Arabic, Devanagari, etc.),
ligatures, kerning, bidirectional text, word wrapping, color emoji. All in
pure Rust -- no OS dependency. This is critical: it means the text stack CAN
work in WASM.

### Reactive Rendering (v0.14+)

Prior to 0.14, entire window redrawn on every event (mouse move, key press).
Since 0.14: runtime only triggers redraw when `update()` processes a message
or widget explicitly requests it. 60-80% CPU reduction for static UIs.

### Critical Trade-offs for zunk

```
Iced Strength                          zunk Relevance
--------------                         --------------
TEA state management                   GREAT FIT (maps to Zig struct + union)
Constraint-based layout (no Taffy)     GREAT FIT (simple, standalone)
Per-capability renderer interfaces     GREAT FIT (comptime checking in Zig)
cosmic-text (pure Rust, no OS deps)    INSPIRING (need Zig equivalent)
Reactive rendering                     ESSENTIAL (WASM GPU bandwidth)
Two-phase prepare/render               GREAT FIT (explicit, cache-friendly)
wgpu backend                           PARTIAL (WebGPU yes, native backends TBD)

Iced Weakness                          zunk Impact
--------------                         ----------
Trait objects for Element (Box<dyn>)    Use tagged unions instead
Lifetime-parameterized trees           Use arenas
Closures for callbacks/styling         Use fn ptrs + context
Virtual DOM diffing                    Skip (immediate mode or explicit invalidation)
Component deprecation (no local state) Support both centralized + local state
No standalone layout engine            Actually build one (standalone, testable)
```

---

## Raw wgpu / WebGPU Path

### WebGPU Browser Support (2025-2026)

WebGPU is production-ready in all major browsers:

```
Browser        Version    Date        Platforms
-------        -------    ----        ---------
Chrome/Edge    113+       Apr 2023    Windows, macOS, ChromeOS, Android 12+
Firefox        141+       Jul 2025    Windows; macOS (Apple Silicon, 145+)
Safari         26+        Jun 2025    macOS Tahoe, iOS 26, iPadOS 26
```

Remaining gap: Linux (Chrome doing driver-specific rollouts, Firefox has it in
Nightly). Expected stable throughout 2026.

### Zig + WebGPU Binding Options

| Project | Backend | Maturity | Notes |
|---------|---------|----------|-------|
| Mach/sysgpu | Dawn | Highest | Archived into Mach monorepo. Developing sysgpu (WebGPU descendant) |
| bronter/wgpu_native_zig | wgpu-native | Medium | Pure Zig extern fn, idiomatic API |
| webgpu.h convergence | Dawn + wgpu | In progress | Shared C header, not yet fully aligned |

### Direct WebGPU from WASM (the zunk path)

This is the most natural fit. The pattern:

```
Zig (wasm32-freestanding)
  |
  extern "env" fn zunk_gpu_create_render_pipeline(...)
  extern "env" fn zunk_gpu_render_pass_draw(...)
  |
  v
Generated JS bridge (zunk gen/ layer)
  |
  Maps extern names -> browser navigator.gpu.* API calls
  |
  v
Browser WebGPU implementation
```

**We already have this.** `src/web/gpu.zig` already defines 30+ WebGPU extern
functions with handle-based resource management. The bridge pattern (integer
handle <-> JS object Map) is identical to what `juj/wasm_webgpu` does for
C/Emscripten.

### WASM-Specific Constraints

1. **Async mismatch**: WebGPU is async (requestAdapter, requestDevice,
   mapAsync). WASM code is synchronous. Requires callback-based patterns.
2. **Descriptor marshalling**: WebGPU JS API uses nested descriptor objects.
   Flattening these into positional extern fn arguments is the main complexity.
3. **GC pressure**: JS API generates garbage per frame (descriptor objects).
   Minimize by reusing JS-side objects.
4. **Small workload warning**: For trivially simple UI (few rectangles, some
   text), Canvas 2D may outperform WebGPU due to GPU dispatch overhead.

### Performance Reference Points

```
Metric                                  Value
------                                  -----
WASM CPU vs native                      95%+ (Chrome/Firefox 2025)
wgpu overhead vs raw Vulkan             5-10% typical
WebGPU draw calls vs WebGL              2-5x improvement
Render bundles (static scene replay)    ~10x faster than non-bundled
Small workload: WASM SIMD vs WebGPU     WASM wins (8-12ms vs 15-25ms)
Large batched: WebGPU vs WASM CPU       WebGPU wins dramatically
```

---

## Zig-Idiomatic Analysis

### What Makes a UI Framework "Zig-Idiomatic"?

Zig's philosophy: explicit allocation, comptime metaprogramming, no hidden
control flow, minimal runtime, no garbage collector, and first-class WASM
target. A Zig UI framework should leverage these:

### 1. Comptime Interface Checking (replaces traits/vtables)

Instead of Iced's `Widget<Message, Theme, Renderer>` trait hierarchy:

```zig
fn renderWidget(comptime W: type, widget: *W, backend: anytype) void {
    // Comptime checks that backend has required capabilities
    comptime {
        if (!@hasDecl(@TypeOf(backend), "fillQuad"))
            @compileError("Backend must implement fillQuad");
        if (!@hasDecl(@TypeOf(backend), "drawText"))
            @compileError("Backend must implement drawText");
    }
    widget.render(backend);
}
```

This gives us Iced's per-capability renderer checking without trait objects,
vtables, or dynamic dispatch. Zero runtime cost.

### 2. Tagged Unions for Widget Types (replaces Box<dyn Widget>)

If the widget set is closed (framework-controlled):

```zig
const Widget = union(enum) {
    button: Button,
    text: Text,
    container: Container,
    row: Row,
    column: Column,
    slider: Slider,
    canvas: Canvas,
    // ...

    pub fn layout(self: *Widget, limits: Limits) Node {
        return switch (self.*) {
            inline else => |*w| w.layout(limits),
        };
    }
};
```

No heap allocation per widget. No vtable indirection. The `inline else` pattern
gives us static dispatch through a tagged union -- a Zig specialty.

### 3. Arena-Per-Frame Allocation

GPUI uses `bumpalo` for per-frame element allocation. Zig has first-class arena
allocators:

```zig
var frame_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer frame_arena.deinit();

// All widget tree allocations use frame_arena.allocator()
// At frame end, one deinit() frees everything
const tree = buildWidgetTree(frame_arena.allocator(), state);
layout(tree);
paint(tree, gpu);
// frame_arena.deinit() -- done, zero individual frees
```

### 4. Flat Array Layout (cache-friendly)

Instead of pointer-heavy trees, use flat arrays with indices:

```zig
const WidgetId = u16;

const WidgetNode = struct {
    widget: Widget,
    parent: WidgetId,
    first_child: WidgetId,
    next_sibling: WidgetId,
    layout: LayoutRect,
};

// Entire widget tree in one contiguous allocation
widgets: []WidgetNode,
```

Cache-friendly iteration. Layout pass walks the array linearly. No pointer
chasing.

### 5. Messages as Tagged Unions (natural TEA)

Zig tagged unions are a perfect fit for TEA messages:

```zig
const Message = union(enum) {
    button_clicked: ButtonId,
    slider_changed: struct { id: SliderId, value: f32 },
    text_input: struct { id: InputId, text: []const u8 },
    tick: f32,
    resize: struct { w: u32, h: u32 },
};
```

Switch exhaustiveness checking ensures all messages are handled.

### 6. Polling-Based Input (already have this)

zunk's existing `input.poll()` -> shared memory struct model is already
game-friendly and avoids the callback complexity that GPUI and Iced wrestle
with. For UI, we extend it with hit testing:

```zig
pub fn frame(dt: f32) void {
    input.poll();
    const mouse = input.getMouse();

    // Build UI, check interactions
    if (ui.button("Click me", .{ .x = 100, .y = 50 })) {
        // button was clicked this frame
    }
}
```

This is the egui model -- immediate mode with polling input. It is the most
Zig-idiomatic approach because it has zero hidden control flow.

---

## Head-to-Head Comparison

### Architecture Comparison

```
Dimension          GPUI                  Iced                  Proposed (zunk)
---------          ----                  ----                  ---------------
State mgmt         Entity system         TEA (Elm arch)        TEA + local state
                   (SlotMap, leases)     (single struct)       (struct + widget state arena)

Widget model       Trait objects          Trait objects          Tagged unions
                   (Box<dyn Element>)    (Box<dyn Widget>)     (no heap alloc per widget)

Layout engine      Taffy (flexbox)       Custom per-widget     Standalone module
                                         (Limits propagation)  (Limits-inspired, testable)

Rendering          Custom shaders         wgpu pipelines       WebGPU custom shaders
                   per primitive          (quad/text/tri/img)  (quad/text/sprite -- WGSL only)

Text rendering     OS APIs               cosmic-text           Canvas2D shaping (Phase A)
                   (CoreText, DWrite)    (pure Rust, portable) SDF atlas (Phase B)

Input model        Capture/bubble        Event -> Message      Polling + hit testing
                   (DOM-style)           (TEA messages)        (immediate mode)

Reactivity         Effect queue,          Reactive rendering   Explicit invalidation
                   whole-window redraw   (0.14+, dirty flag)  (dirty flag per region)

Shader languages   MSL + WGSL + HLSL    WGSL (via wgpu)      WGSL only

WASM support       Structurally blocked   Partial (WebGL)      First-class target
```

### What Each Framework Solved vs What zunk Needs

```
Problem                      GPUI Solution        Iced Solution        zunk Needs
-------                      -------------        -------------        ----------
Rust ownership hell          Entity system        TEA purity           N/A (no borrow checker)
Cross-platform native look   OS font APIs         cosmic-text          WASM-compatible text
GPU rendering                Custom shaders       wgpu pipelines       WebGPU direct bridge
Complex state management     Entities + effects   TEA + Tasks          TEA-inspired + local state
Layout                       Taffy (full flex)    Custom (Limits)      Standalone Limits engine
Accessibility                Unsolved             Early-stage          Hidden DOM overlay (browser)
120 FPS editor               Yes                  Not designed for     Not primary goal
Form-based UI                Struggled            Moderate             Must support
Game-style rendering         Yes                  Not designed for     Yes (existing strength)
```

### Complexity Budget

```
Framework    Lines of Zig    Shader Count    External Deps    Risk
---------    ------------    ------------    -------------    ----
GPUI-style   ~15k-25k        5-6 (x1 lang)  Taffy or equiv   High (scope)
Iced-style   ~10k-15k        3-4 (x1 lang)  cosmic-text eq   High (text stack)
Proposed     ~5k-8k          3 (WGSL only)   None             Medium
```

---

## Recommendation for zunk

### The "Zunk UI" Architecture

A purpose-built immediate-mode-inspired UI framework with these properties:

**1. Rendering: Three WGSL Shaders**

```
Shader 1: Quad
  - Rounded rectangles via SDF (GPUI technique)
  - Borders (per-side width + color)
  - Solid and gradient fills
  - Drop shadows (Evan Wallace closed-form)
  Input: instance buffer of QuadPrimitive structs
  One instanced draw call per layer

Shader 2: Glyph
  - Textured quads sampling from glyph atlas
  - Alpha-only atlas, color applied in shader (GPUI technique)
  - Subpixel positioning
  Input: instance buffer of GlyphPrimitive structs
  One instanced draw call per layer

Shader 3: Sprite
  - Full RGBA textured quads (images, icons, emoji)
  - Atlas-packed for minimal bind group switches
  Input: instance buffer of SpritePrimitive structs
  One instanced draw call per layer
```

This covers 95%+ of UI rendering needs. Three shaders, one language (WGSL),
three instanced draw calls per layer. Compare to GPUI's 5-6 primitives across
3 shader languages.

**2. Layout: Standalone Limits Engine**

Take Iced's Limits propagation model but implement it as a standalone,
testable module. Not per-widget -- a single layout algorithm that operates
on a flat array of layout nodes:

```zig
const LayoutNode = struct {
    sizing: struct { width: Length, height: Length },
    padding: Edges,
    spacing: f32,
    direction: enum { row, column, stack },
    children: IndexRange, // into flat children array
    computed: Rect,       // filled by layout pass
};

pub fn computeLayout(nodes: []LayoutNode, viewport: Size) void {
    // Top-down constraint propagation, bottom-up size resolution
    // Single pass (or two passes for fill-portion distribution)
}
```

**3. Text: Phased Approach**

```
Phase A (now, Canvas 2D backend):
  Use browser's Canvas2D measureText() + fillText() for text
  measurement and rendering. Bridge via existing canvas.zig.
  Ship fast, iterate on the UI framework, discover real needs.

Phase B (when Canvas2D becomes bottleneck):
  Rasterize glyphs via Canvas2D into ImageData, upload to
  WebGPU texture atlas. Render as GlyphPrimitives.
  Browser still does shaping/rasterization (free complex script
  support), but rendering moves to GPU pipeline.

Phase C (if needed -- SDF):
  SDF font atlas for resolution-independent text.
  Only pursue if Phase B proves insufficient (unlikely for UI).
```

The key insight: browsers are excellent at text. Even GPUI delegates to OS
text APIs. In WASM, the browser IS our OS. Using Canvas2D for text
shaping/rasterization and WebGPU for everything else is the pragmatic path.

**4. State Management: TEA-Inspired with Local State**

```zig
// Application state
const App = struct {
    counter: u32 = 0,
    name: [256]u8 = undefined,
    name_len: u32 = 0,
    panel_open: bool = true,
};

// Messages -- exhaustive tagged union
const Msg = union(enum) {
    increment,
    decrement,
    name_changed: []const u8,
    toggle_panel,
};

// Update -- pure state transition
fn update(app: *App, msg: Msg) void {
    switch (msg) {
        .increment => app.counter += 1,
        .decrement => app.counter -|= 1,
        .name_changed => |text| @memcpy(app.name[0..text.len], text),
        .toggle_panel => app.panel_open = !app.panel_open,
    }
}

// View -- pure function from state to UI (immediate mode)
fn view(app: *const App, ui: *Ui) void {
    ui.column(.{ .gap = 8, .padding = 16 }, struct {
        fn build(a: *const App, u: *Ui) void {
            u.text("Counter: {}", .{a.counter});
            if (u.button("+ Increment")) u.send(.increment);
            if (u.button("- Decrement")) u.send(.decrement);
        }
    }.build, app);
}
```

This keeps TEA's clarity (unidirectional data flow, exhaustive message
handling) while using immediate-mode ergonomics (no widget tree allocation,
no diffing). Widgets return booleans for interaction (the egui pattern).

Widget-local state (scroll position, text cursor, animation progress) lives
in a separate arena keyed by widget identity, not in the application state.

**5. Input: Extend Existing Polling Model**

Keep `input.poll()` with shared memory struct. Add hit testing:

```zig
const HitResult = struct {
    hovered: bool,
    clicked: bool,
    right_clicked: bool,
    dragging: bool,
};

fn hitTest(rect: Rect, mouse: Mouse) HitResult { ... }
```

The UI framework calls hitTest internally for interactive widgets. No event
dispatch, no capture/bubble, no focus management complexity. If focus
management becomes needed later, add it as a focused-widget-id tracked in the
UI context -- not an event dispatch tree.

**6. Accessibility: Hidden DOM Overlay**

Since we are in a browser, generate hidden DOM elements that mirror the
widget tree for screen readers. This is how Google Docs solved accessibility
for canvas-rendered text. zunk's gen/ layer can emit a `<div>` overlay with
ARIA attributes alongside the WebGPU canvas.

### What We Do NOT Build

- No full CSS Flexbox/Grid engine (Limits is simpler and sufficient)
- No virtual DOM diffing (immediate mode eliminates this)
- No trait objects / dynamic dispatch for widgets (tagged unions)
- No multiple shader languages (WGSL only)
- No native platform backends initially (WebGPU browser first)
- No component lifecycle system (immediate mode handles this)
- No async task/subscription system (polling + frame callbacks)

---

## Evolution Roadmap

How zunk evolves from current state to GPU-accelerated UI:

### Phase 0: Current State (what exists today)

```
src/web/canvas.zig  -- Canvas 2D bridge (fillRect, fillText, etc.)
src/web/gpu.zig     -- WebGPU bridge (buffers, pipelines, render passes)
src/web/input.zig   -- Polling input (keyboard, mouse, touch, gamepad)
src/web/ui.zig      -- DOM-proxy UI (panels, sliders, buttons via generated JS)
```

The DOM-proxy UI (`ui.zig`) provides functional controls but is not
GPU-rendered and relies on generated HTML/CSS.

### Phase 1: Immediate-Mode Canvas2D UI (current plan, fast path)

Build an immediate-mode widget system on top of `canvas.zig`:

```
src/web/ui.zig  -->  rewrite as immediate-mode API
                     Layout: Limits-based engine (standalone module)
                     Rendering: Canvas 2D (fillRect, fillText)
                     Input: extend input.zig with hit testing
                     State: TEA-inspired update/view pattern
```

This is Phase A from `ui_convo.md`. Ship fast, learn from real use.

Exit criteria: when Canvas 2D becomes the rendering bottleneck.

### Phase 2: GPU Backend Swap (the pivot)

Replace Canvas 2D rendering with WebGPU. The widget API stays the same --
only the backend changes (comptime interface swap):

```
src/web/ui.zig           -- same immediate-mode API
src/ui/                  -- new directory
  layout.zig             -- standalone Limits-based layout engine
  render.zig             -- render backend interface (comptime)
  backend_canvas.zig     -- Canvas 2D backend (kept for simple apps)
  backend_gpu.zig        -- WebGPU backend (new)
  shaders/
    quad.wgsl            -- SDF rounded rects + shadows
    glyph.wgsl           -- text atlas rendering
    sprite.wgsl          -- image/icon rendering
  primitives.zig         -- QuadPrimitive, GlyphPrimitive, SpritePrimitive
  atlas.zig              -- glyph + sprite atlas management
  text.zig               -- Canvas2D -> atlas upload for text
```

The backend swap is a comptime decision:

```zig
const Backend = if (use_gpu) GpuBackend else CanvasBackend;
var ui = Ui(Backend).init(allocator);
```

### Phase 3: Native Backend (Vulkan)

When/if we target native desktop:

```
src/ui/
  backend_vulkan.zig     -- Vulkan backend (via vulkan-zig)
                            Same shaders (WGSL -> SPIR-V via naga or Zig SPIR-V backend)
                            Same primitives, same layout, same API
```

Same Zig application code, same UI framework. `zig build` produces native
(Vulkan). `zig build -Dtarget=wasm32-freestanding` produces WASM (WebGPU).

### Phase 4: Advanced (if needed)

- SDF font atlas (resolution-independent text)
- Compute shader layout (GPU-accelerated layout for large trees)
- Render bundles (WebGPU GPURenderBundle for static UI regions)
- Partial invalidation (dirty-region tracking for large UIs)

---

## Key Takeaways

1. **GPUI is the wrong model for zunk.** It solves Rust-specific problems (borrow
   checker), depends on OS APIs (text rendering), and is structurally blocked
   from WASM. Its rendering techniques (SDF quads, closed-form shadows,
   instanced batching, glyph atlases) are excellent and should be adopted
   directly.

2. **Iced's architecture maps better to Zig**, especially TEA state management,
   constraint-based layout, per-capability renderer interfaces, and the
   two-phase prepare/render split. Its Rust-specific patterns (trait objects,
   closures, lifetime-parameterized trees) need to be replaced with Zig-native
   equivalents (tagged unions, fn pointers, arenas).

3. **Neither is the answer. Build a third thing.** A Zig-native immediate-mode
   UI framework with: GPUI's rendering techniques, Iced's layout philosophy,
   egui's API simplicity, and zunk's existing WebGPU bridge. WGSL-only shaders.
   No external dependencies. Comptime interface checking. Tagged union widgets.
   Arena-per-frame allocation.

4. **Start with Canvas 2D, pivot to WebGPU.** The API should be designed for
   backend-swappability from day one (comptime render backend interface). Start
   shipping with Canvas 2D. When it becomes the bottleneck, swap the backend
   without changing the widget API.

5. **Text is the hard problem.** Both GPUI and Iced delegate to external text
   stacks. For WASM, use the browser's Canvas2D for shaping/rasterization and
   upload glyphs to a WebGPU atlas. This gives us free complex script support
   without reimplementing HarfBuzz in Zig.

6. **WebGPU is ready.** Browser support is production-grade across Chrome,
   Firefox, and Safari. zunk's existing `gpu.zig` bridge pattern (extern fn +
   handle table + generated JS) is the right architecture for WASM WebGPU.
   No need for wgpu-native or Dawn in the browser path.

---

## Sources

### GPUI
- Zed Blog: "Leveraging Rust and the GPU to render user interfaces at 120 FPS"
- Zed Blog: "Ownership and data flow in GPUI"
- GPUI README (github.com/zed-industries/zed/crates/gpui)
- Evan Wallace: "Fast Rounded Rectangle Shadows" (madebyevan.com)
- GPUI Community Edition discussion (gpui-ce/gpui-ce)

### Iced
- Iced Official Book (book.iced.rs) -- Architecture, First Steps, Runtime
- Iced GitHub (github.com/iced-rs/iced)
- Custom layout engine PR #52
- Reactive rendering PR #2662
- cosmic-text (github.com/pop-os/cosmic-text)
- glyphon (crates.io/crates/glyphon)

### WebGPU / Zig Ecosystem
- WebGPU Implementation Status (W3C gpuweb wiki)
- juj/wasm_webgpu -- WASM-to-WebGPU bridge (github.com)
- Mach Engine / sysgpu (machengine.org)
- Snektron/vulkan-zig (github.com)
- bronter/wgpu_native_zig (github.com)
- webgpu-native/webgpu-headers shared C header (github.com)
- Zig SPIR-V backend (github.com/ziglang/zig)
- Figma WebGPU migration blog posts
