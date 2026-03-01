# WebGPU Particle Life Migration Plan

## Objective

Migrate the reference WebGPU particle accelerator (`ref/old_zig-wasm-ffi/`) into a
pure-Zig project built on zunk. Zero hand-written JS or HTML. This migration is the
vehicle for maturing zunk's WebGPU capabilities and Layer 2 API.

---

## Current State Assessment

### What zunk has today
- `bind.Handle` -- unified JS object handle (i32 <-> JS Map)
- `web/canvas.zig` -- Canvas 2D (via `zunk_c2d_*` / `zunk_canvas_*` extern fns)
- `web/input.zig` -- polling-based input (shared memory struct, 236 lines)
- `web/audio.zig` -- Web Audio API wrapper + `decodeAsset()` bridge
- `web/asset.zig` -- generic URL-based asset loading (fetch/isReady/getLen/getBytes)
- `web/app.zig` -- lifecycle + logging
- `gen/js_resolve.zig` -- 5-tier resolver; `.asset` category implemented; WebGPU has 6 stubby entries in `genWebGPU`
- `gen/js_gen.zig` -- full JS/HTML generator with handle table, input system, render loop
- `gen/serve.zig` -- dev server with live reload
- `gen/wasm_analyze.zig` -- WASM binary parser
- `main.zig` -- CLI with convention-based asset copying (`src/assets/` -> `dist/assets/`)
- `examples/input-demo/` -- working Canvas 2D example
- `examples/audio-demo-1-assets-bundled/` -- audio with @embedFile
- `examples/audio-demo-2-assets-cached/` -- audio with asset.fetch + decodeAsset

### What the ref particle life has
- ~90 WebGPU FFI functions across `js_webgpu_*` / `env_webgpu_*` naming
- 13 typed handle wrappers (Device, Buffer, Shader, Texture, etc.)
- Zig WebGPU abstractions: buffer, shader, pipeline, compute, texture, device, render
- Particle simulation: spatial binning, prefix sum, force computation, HDR rendering
- ~800 lines of WGSL shaders as comptime strings
- Custom JS bridge (~550 lines) + UI JS (~230 lines) + HTML
- Custom input system with polling struct

### Gap analysis

```
                       zunk today     needed for particle life
                       ----------     -----------------------
WebGPU device init     stub           full (adapter, device, surface configure)
Buffer ops             none           create, write, destroy, copy
Shader modules         1 stub         create from WGSL string
Bind groups/layouts    none           full (buffer + texture bindings, dynamic offsets)
Pipeline layouts       none           create from bind group layout array
Compute pipelines      none           create, dispatch, encoder lifecycle
Render pipelines       none           create (standard + HDR), draw, render pass
Textures               none           create, createView, destroy, HDR format
Command encoders       none           create, beginComputePass, beginRenderPass, finish, submit
Present/frame          none           render to screen texture, present
Asset fetching         DONE           zunk.web.asset (generic fetch + polling)
Asset -> GPU texture   none           image decode + GPU texture upload (blue noise)
Asset copying          DONE           src/assets/ -> dist/assets/ convention
Input                  full           reuse existing system
```

---

## Architecture Decisions

### D1: Handle system
Use zunk's existing `bind.Handle` as the backing type for ALL WebGPU objects.
Provide type aliases in the gpu module for documentation:
```zig
pub const Device = bind.Handle;
pub const Buffer = bind.Handle;
pub const ShaderModule = bind.Handle;
// etc.
```
No separate typed handle structs. The ref project's 13 distinct handle types added
~170 lines of boilerplate for zero runtime benefit (everything is u32 on the FFI
boundary).

### D2: Device lifecycle
Auto-initialized by zunk's generated JS when WebGPU imports are detected.
The generator emits WebGPU setup code (adapter request, device creation, canvas
context configuration) and calls a well-known WASM export `__zunk_gpu_device` to
pass the device handle to Zig. The gpu module stores it in a global.

User code simply calls `gpu.getDevice()` -- the handle is available by the time
`init()` runs because the generator emits setup before calling init.

### D3: Extern fn naming convention
All WebGPU extern fns use the prefix `zunk_gpu_`. The resolver's Tier 2 prefix
match already has a `zunk_gpu_` entry -- we expand it from 6 stubs to the full
~40 operations needed.

The method names after the prefix match the ref project's structure:
```
zunk_gpu_create_buffer          -> device.createBuffer()
zunk_gpu_buffer_write           -> device.queue.writeBuffer()
zunk_gpu_create_shader_module   -> device.createShaderModule()
zunk_gpu_create_bind_group_layout -> device.createBindGroupLayout()
zunk_gpu_create_bind_group      -> device.createBindGroup()
zunk_gpu_create_pipeline_layout -> device.createPipelineLayout()
zunk_gpu_create_compute_pipeline -> device.createComputePipeline()
zunk_gpu_create_render_pipeline -> device.createRenderPipeline()
zunk_gpu_create_command_encoder -> device.createCommandEncoder()
zunk_gpu_begin_compute_pass     -> encoder.beginComputePass()
zunk_gpu_compute_pass_*         -> computePass.*()
zunk_gpu_begin_render_pass      -> encoder.beginRenderPass()
zunk_gpu_render_pass_*          -> renderPass.*()
zunk_gpu_encoder_finish         -> encoder.finish()
zunk_gpu_queue_submit           -> device.queue.submit()
zunk_gpu_create_texture         -> device.createTexture()
zunk_gpu_create_texture_view    -> texture.createView()
zunk_gpu_present                -> commandEncoder.finish() + queue.submit()
zunk_gpu_copy_buffer            -> encoder.copyBufferToBuffer()
```

### D4: Module structure
One file: `src/web/gpu.zig`. Despite the complexity, the API surface is flat --
it's all extern fn declarations + thin wrapper functions. No deep nesting, no
separate abstractions to justify multiple files. Follows the same pattern as
`canvas.zig`. The particle life project's own simulation modules stay in the
example project, not in zunk core.

### D5: Render-to-screen abstraction
The generator creates a `commandEncoder` and `renderPassEncoder` module-level
variable in the generated JS (like the ref project does). The Zig API has:
- `gpu.beginRenderPassToScreen(r, g, b, a) -> Handle` -- renders to canvas surface
- `gpu.beginRenderPassToTexture(texture_view, r, g, b, a) -> Handle` -- renders to offscreen texture (HDR)
- `gpu.present()` -- finalizes the command encoder and submits

This matches the ref project's `env_webgpu_begin_render_pass_for_particles` /
`env_webgpu_begin_render_pass_hdr` / `env_webgpu_present` pattern.

### D6: Particle life project structure
Lives in `examples/particle-life/` as a standalone zunk project, same pattern as
`examples/input-demo/`. Uses `zunk` as a dependency, imports `zunk.web.gpu`,
`zunk.web.input`, `zunk.web.app`.

### D7: UI approach
Phase 1: No UI panel. Just the simulation with mouse interaction (attract/repel,
pan, zoom). Configuration hardcoded with reasonable defaults.

Phase 2 (future, not in this plan): zunk UI module or bridge.js for sliders/buttons.

### D8: Blue noise texture
**Updated:** Generic asset fetching now exists via `zunk.web.asset`. The blue
noise PNG follows the same two-stage pattern as audio:

```zig
const asset = zunk.web.asset;

// In init:
noise_asset = asset.fetch("assets/blue-noise.png");

// In frame (before simulation starts):
if (!noise_ready) {
    if (asset.isReady(noise_asset)) {
        noise_texture = gpu.createTextureFromAsset(noise_asset);
        // or: gpu.uploadImageToTexture(noise_asset) if we want a combined call
    }
    if (gpu.isTextureReady(noise_texture)) {
        noise_ready = true;
    }
}
```

What remains GPU-specific: a `gpu.createTextureFromAsset(asset_handle)` function
that takes a fetched ArrayBuffer, decodes it as an image via `createImageBitmap`,
creates a GPU texture, and uploads via `copyExternalImageToTexture`. This is the
GPU analog of `audio.decodeAsset()`.

The JS resolver entry for `create_texture_from_asset`:
```javascript
const buf = H.get(arguments[0]);
if (!(buf instanceof ArrayBuffer)) return 0;
const h = H.nextId();
createImageBitmap(new Blob([buf]), {colorSpaceConversion:'none'})
.then(bmp => {
  const tex = H.get(1).createTexture({
    format:'rgba8unorm',
    size:[bmp.width,bmp.height],
    usage: 0x06,  // COPY_DST | TEXTURE_BINDING
  });
  H.get(1).queue.copyExternalImageToTexture(
    {source:bmp},{texture:tex},{width:bmp.width,height:bmp.height});
  H.set(h, tex);
});
return h;
```

No callbacks needed -- uses the same polling pattern as all other async ops.
The convention-based asset copying (`src/assets/` -> `dist/assets/`) handles
getting blue-noise.png into the output directory automatically.

---

## Implementation Phases

### Phase 1: WebGPU Layer 2 Module (`src/web/gpu.zig`)

The core of the migration. Build the Zig API that wraps WebGPU operations.

**File: `src/web/gpu.zig`**

Extern fn declarations (~40 functions):
```
Device & Resource Creation
  zunk_gpu_create_buffer(size: u32, usage: u32) -> i32
  zunk_gpu_buffer_write(buffer: i32, offset: u32, data_ptr: [*]const u8, data_len: u32) -> void
  zunk_gpu_buffer_destroy(buffer: i32) -> void
  zunk_gpu_copy_buffer_in_encoder(encoder: i32, src: i32, src_off: u32, dst: i32, dst_off: u32, size: u32) -> void
  zunk_gpu_create_shader_module(source_ptr: [*]const u8, source_len: u32) -> i32
  zunk_gpu_create_texture(width: u32, height: u32, format: u32, usage: u32) -> i32
  zunk_gpu_create_texture_view(texture: i32) -> i32
  zunk_gpu_destroy_texture(texture: i32) -> void

Bind Groups & Layouts
  zunk_gpu_create_bind_group_layout(entries_ptr: [*]const u8, entries_len: u32) -> i32
  zunk_gpu_create_bind_group(layout: i32, entries_ptr: [*]const u8, entries_len: u32) -> i32
  zunk_gpu_create_pipeline_layout(layouts_ptr: [*]const u8, layouts_len: u32) -> i32

Compute Pipelines
  zunk_gpu_create_compute_pipeline(layout: i32, shader: i32, entry_ptr: [*]const u8, entry_len: u32) -> i32
  zunk_gpu_create_command_encoder() -> i32
  zunk_gpu_begin_compute_pass(encoder: i32) -> i32
  zunk_gpu_compute_pass_set_pipeline(pass: i32, pipeline: i32) -> void
  zunk_gpu_compute_pass_set_bind_group(pass: i32, index: u32, group: i32) -> void
  zunk_gpu_compute_pass_set_bind_group_offset(pass: i32, index: u32, group: i32, offset: u32) -> void
  zunk_gpu_compute_pass_dispatch(pass: i32, x: u32, y: u32, z: u32) -> void
  zunk_gpu_compute_pass_end(pass: i32) -> void
  zunk_gpu_encoder_finish(encoder: i32) -> i32
  zunk_gpu_queue_submit(cmd_buffer: i32) -> void

Render Pipelines
  zunk_gpu_create_render_pipeline(layout: i32, shader: i32, ...) -> i32
  zunk_gpu_create_render_pipeline_hdr(layout: i32, shader: i32, ..., format: u32, blending: u32) -> i32
  zunk_gpu_begin_render_pass(r: f32, g: f32, b: f32, a: f32) -> i32
  zunk_gpu_begin_render_pass_hdr(texture_view: i32, r: f32, g: f32, b: f32, a: f32) -> i32
  zunk_gpu_render_pass_set_pipeline(pass: i32, pipeline: i32) -> void
  zunk_gpu_render_pass_set_bind_group(pass: i32, index: u32, group: i32) -> void
  zunk_gpu_render_pass_draw(pass: i32, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) -> void
  zunk_gpu_render_pass_end(pass: i32) -> void
  zunk_gpu_present() -> void

Image Texture from Asset
  zunk_gpu_create_texture_from_asset(asset_handle: i32) -> i32
  zunk_gpu_is_texture_ready(handle: i32) -> i32
```

Public Zig API (thin wrappers):
```zig
// Type aliases (all bind.Handle underneath)
pub const Device = bind.Handle;
pub const Buffer = bind.Handle;
pub const ShaderModule = bind.Handle;
pub const Texture = bind.Handle;
pub const TextureView = bind.Handle;
pub const BindGroupLayout = bind.Handle;
pub const BindGroup = bind.Handle;
pub const PipelineLayout = bind.Handle;
pub const ComputePipeline = bind.Handle;
pub const RenderPipeline = bind.Handle;
pub const CommandEncoder = bind.Handle;
pub const ComputePassEncoder = bind.Handle;
pub const RenderPassEncoder = bind.Handle;
pub const CommandBuffer = bind.Handle;

// Usage flags (matching WebGPU GPUBufferUsage / GPUTextureUsage)
pub const BufferUsage = struct {
    pub const MAP_READ: u32 = 0x0001;
    pub const MAP_WRITE: u32 = 0x0002;
    pub const COPY_SRC: u32 = 0x0004;
    pub const COPY_DST: u32 = 0x0008;
    pub const INDEX: u32 = 0x0010;
    pub const VERTEX: u32 = 0x0020;
    pub const UNIFORM: u32 = 0x0040;
    pub const STORAGE: u32 = 0x0080;
    pub const INDIRECT: u32 = 0x0100;
    pub const QUERY_RESOLVE: u32 = 0x0200;
};

pub const TextureUsage = struct {
    pub const COPY_SRC: u32 = 0x01;
    pub const COPY_DST: u32 = 0x02;
    pub const TEXTURE_BINDING: u32 = 0x04;
    pub const STORAGE_BINDING: u32 = 0x08;
    pub const RENDER_ATTACHMENT: u32 = 0x10;
};

pub const TextureFormat = enum(u32) {
    rgba16float = 0,
    rgba32float = 1,
    bgra8unorm = 2,
    rgba8unorm = 3,
    rgba8unorm_srgb = 4,
    depth24plus = 5,
    depth32float = 6,
};

pub const ShaderVisibility = struct {
    pub const VERTEX: u32 = 1;
    pub const FRAGMENT: u32 = 2;
    pub const COMPUTE: u32 = 4;
};

// --- BindGroupLayoutEntry (40 bytes, extern struct, matches JS DataView) ---
pub const BindGroupLayoutEntry = extern struct {
    binding: u32,
    visibility: u32,
    entry_type: u32,    // 0=buffer, 1=texture, 2=sampler
    buffer_type: u32,   // 0=uniform, 1=storage, 2=read-only-storage
    has_min_size: u32,
    has_dynamic_offset: u32,
    min_size: u64,
    _padding: u64 = 0,

    // Builder functions (same pattern as ref project)
    pub fn initBuffer(b: u32, vis: u32, buf_type: enum { uniform, storage, read_only_storage }) BindGroupLayoutEntry { ... }
    pub fn initTexture(b: u32, vis: u32) BindGroupLayoutEntry { ... }
    pub fn withDynamicOffset(self: BindGroupLayoutEntry) BindGroupLayoutEntry { ... }
};

// --- BindGroupEntry (32 bytes, extern struct) ---
pub const BindGroupEntry = extern struct {
    binding: u32,
    entry_type: u32,    // 0=buffer, 1=texture_view
    resource_handle: u32,
    _padding: u32 = 0,
    offset: u64,
    size: u64,

    pub fn initBuffer(b: u32, handle: bind.Handle, offset: u64, size: u64) BindGroupEntry { ... }
    pub fn initBufferFull(b: u32, handle: bind.Handle, size: u64) BindGroupEntry { ... }
    pub fn initTextureView(b: u32, handle: bind.Handle) BindGroupEntry { ... }
};

// --- High-level operations ---
pub fn getDevice() Device { ... }  // returns the auto-initialized device handle

pub fn createBuffer(size: u32, usage: u32) Buffer { ... }
pub fn createStorageBuffer(size: u32) Buffer { ... }    // convenience
pub fn createUniformBuffer(size: u32) Buffer { ... }    // convenience
pub fn bufferWrite(buf: Buffer, offset: u32, data: []const u8) void { ... }
pub fn bufferWriteTyped(comptime T: type, buf: Buffer, offset: u32, items: []const T) void { ... }
pub fn bufferDestroy(buf: Buffer) void { ... }

pub fn createShaderModule(source: []const u8) ShaderModule { ... }

pub fn createTexture(w: u32, h: u32, fmt: TextureFormat, usage: u32) Texture { ... }
pub fn createTextureView(tex: Texture) TextureView { ... }
pub fn destroyTexture(tex: Texture) void { ... }
pub fn createHDRTexture(w: u32, h: u32) Texture { ... }  // convenience

pub fn createBindGroupLayout(entries: []const BindGroupLayoutEntry) BindGroupLayout { ... }
pub fn createBindGroup(layout: BindGroupLayout, entries: []const BindGroupEntry) BindGroup { ... }
pub fn createPipelineLayout(layouts: []const BindGroupLayout) PipelineLayout { ... }

pub fn createComputePipeline(layout: PipelineLayout, shader: ShaderModule, entry_point: []const u8) ComputePipeline { ... }
pub fn createRenderPipeline(layout: PipelineLayout, shader: ShaderModule, vertex_entry: []const u8, fragment_entry: []const u8) RenderPipeline { ... }
pub fn createRenderPipelineHDR(layout: PipelineLayout, shader: ShaderModule, vertex_entry: []const u8, fragment_entry: []const u8, format: TextureFormat, blending: bool) RenderPipeline { ... }

pub fn createCommandEncoder() CommandEncoder { ... }
pub fn beginComputePass(encoder: CommandEncoder) ComputePassEncoder { ... }
pub fn computePassSetPipeline(pass: ComputePassEncoder, pip: ComputePipeline) void { ... }
pub fn computePassSetBindGroup(pass: ComputePassEncoder, index: u32, group: BindGroup) void { ... }
pub fn computePassSetBindGroupWithOffset(pass: ComputePassEncoder, index: u32, group: BindGroup, offset: u32) void { ... }
pub fn computePassDispatch(pass: ComputePassEncoder, x: u32, y: u32, z: u32) void { ... }
pub fn computePassEnd(pass: ComputePassEncoder) void { ... }
pub fn encoderCopyBuffer(encoder: CommandEncoder, src: Buffer, src_off: u32, dst: Buffer, dst_off: u32, size: u32) void { ... }
pub fn encoderFinish(encoder: CommandEncoder) CommandBuffer { ... }
pub fn queueSubmit(cmd: CommandBuffer) void { ... }

pub fn beginRenderPass(r: f32, g: f32, b: f32, a: f32) RenderPassEncoder { ... }
pub fn beginRenderPassHDR(view: TextureView, r: f32, g: f32, b: f32, a: f32) RenderPassEncoder { ... }
pub fn renderPassSetPipeline(pass: RenderPassEncoder, pip: RenderPipeline) void { ... }
pub fn renderPassSetBindGroup(pass: RenderPassEncoder, index: u32, group: BindGroup) void { ... }
pub fn renderPassDraw(pass: RenderPassEncoder, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void { ... }
pub fn renderPassEnd(pass: RenderPassEncoder) void { ... }
pub fn present() void { ... }
```

This is ~200-300 lines. Matches the scale of canvas.zig (132 lines) given the
larger API surface.

**Changes to `src/root.zig`:**
- Add `pub const gpu = @import("web/gpu.zig");` to the `web` namespace
- Add `__zunk_gpu_device` to comptime force-exports (device handle receiver)

---

### Phase 2: JS Resolver WebGPU Expansion (`src/gen/js_resolve.zig`)

Replace the 6-stub `genWebGPU` function with a complete resolver covering all
~40 operations. Each entry maps a method name (after stripping `zunk_gpu_` prefix)
to its JavaScript implementation body.

The JS bodies follow the same pattern as the ref project's `webgpu.js`, using:
- `H.get(id)` to retrieve WebGPU objects from handle table
- `H.store(obj)` to store new objects
- `new DataView(memory.buffer, ptr, len)` for structured data (bind group entries)
- `new TextDecoder().decode(...)` via `readStr()` for strings
- `arguments[N]` for function parameters

Example entries:
```
"create_buffer" ->
  "const b=H.get(1).createBuffer({size:arguments[0],usage:arguments[1]}); return H.store(b);"

"buffer_write" ->
  "H.get(1).queue.writeBuffer(H.get(arguments[0]),arguments[1],new Uint8Array(memory.buffer,arguments[2],arguments[3]));"

"create_shader_module" ->
  "const s=readStr(arguments[0],arguments[1]); return H.store(H.get(1).createShaderModule({code:s}));"

"create_bind_group_layout" ->
  [complex: read struct array from memory, build JS descriptor, create layout]

"begin_compute_pass" ->
  "return H.store(H.get(arguments[0]).beginComputePass());"

"compute_pass_dispatch" ->
  "H.get(arguments[0]).dispatchWorkgroups(arguments[1],arguments[2],arguments[3]);"
```

The bind_group_layout and bind_group resolvers need special handling because
they read structured data from WASM memory (40-byte and 32-byte entries respectively).
These use the same DataView parsing approach as the ref project's `webgpu.js`.

**Confidence levels:**
- All `zunk_gpu_*` entries: `exact` confidence
- All set `needs_handles = true`
- String-related ops also set `needs_string_helper = true`
- Memory-reading ops set `needs_memory_view = true`

---

### Phase 3: JS Generator WebGPU Support (`src/gen/js_gen.zig`)

**New feature flag:**
```zig
const Features = struct {
    // ... existing ...
    webgpu_init: bool = false,  // NEW
};
```

Set when `categories_used.contains(.webgpu)`.

**New emitter: `emitWebGPUInit`**

Generates the WebGPU initialization sequence that runs BEFORE `exports.init()`:
```javascript
// --- WebGPU initialization ---
if (!navigator.gpu) throw new Error('WebGPU not supported');
const zunkGPUAdapter = await navigator.gpu.requestAdapter();
if (!zunkGPUAdapter) throw new Error('No WebGPU adapter');
const zunkGPUDevice = await zunkGPUAdapter.requestDevice();
const zunkGPUFormat = navigator.gpu.getPreferredCanvasFormat();
const zunkGPUCanvas = document.getElementById('app');
const zunkGPUContext = zunkGPUCanvas.getContext('webgpu');
zunkGPUContext.configure({
  device: zunkGPUDevice,
  format: zunkGPUFormat,
  alphaMode: 'opaque',
});
H.store(zunkGPUDevice);  // Always handle 1
```

This is placed after WASM instantiation, after Handle table initialization,
but BEFORE `exports.init()`.

**Modify render pass / present JS bodies to reference module-level state:**

The `begin_render_pass` (to screen) JS body needs access to `zunkGPUContext`
and `zunkGPUDevice` to create the command encoder and get the current texture.
These are module-level variables set up by `emitWebGPUInit`.

The `present` JS body finalizes the shared command encoder and submits.

**Module-level JS state for render:**
```javascript
let zunkGPUEncoder = null;
```

The `begin_render_pass` body creates the encoder if null, gets the current
texture, begins a render pass. The `begin_render_pass_hdr` variant targets
an offscreen texture view. The `present` body calls encoder.finish() + submit
and nulls the encoder.

**HTML generation change:**

When WebGPU is detected (`categories_used.contains(.webgpu)`), the HTML
should add the COOP/COEP headers comment and ensure the canvas has
`id="app"`. The current HTML generator already handles canvas detection
for `.webgpu` category -- no changes needed there.

**Resize handler update:**

When WebGPU is used, the resize handler should set canvas width/height
accounting for devicePixelRatio:
```javascript
function zunkResize() {
  const c = document.getElementById('app');
  if (c) {
    const dpr = window.devicePixelRatio || 1;
    c.width = Math.round(c.clientWidth * dpr);
    c.height = Math.round(c.clientHeight * dpr);
  }
  exports.resize(c.width, c.height);
}
```

**CORS headers in dev server:**

The dev server (`serve.zig`) already emits COOP/COEP headers. Verify these
are sufficient for WebGPU (they should be since SharedArrayBuffer requires them
and WebGPU often needs them too).

---

### Phase 4: GPU Texture from Asset (Blue Noise)

**Updated:** Generic asset fetching is done (`zunk.web.asset`). Convention-based
asset copying (`src/assets/` -> `dist/assets/`) is done. What remains is the
GPU-specific decoder that takes a fetched ArrayBuffer and creates a GPU texture.

This is a small addition to `gpu.zig` (2 externs, 2 public functions):

**Zig API:**
```zig
pub fn createTextureFromAsset(asset_handle: asset.Handle) Texture {
    return bind.Handle.fromInt(zunk_gpu_create_texture_from_asset(asset_handle.toInt()));
}

pub fn isTextureReady(handle: Texture) bool {
    return zunk_gpu_is_texture_ready(handle.toInt()) != 0;
}
```

**JS resolver entries added to `genWebGPU`:**
```
"create_texture_from_asset" ->
  Blob decode + createImageBitmap + createTexture + copyExternalImageToTexture
  (see D8 for full JS body)

"is_texture_ready" ->
  "const t=H.get(arguments[0]); return t instanceof GPUTexture ? 1 : 0;"
```

**Usage in particle life:**
```zig
const asset = zunk.web.asset;
const gpu = zunk.web.gpu;

// In init:
noise_asset = asset.fetch("assets/blue-noise.png");

// In frame (loading phase):
if (asset.isReady(noise_asset)) {
    noise_texture = gpu.createTextureFromAsset(noise_asset);
}
if (gpu.isTextureReady(noise_texture)) {
    noise_view = gpu.createTextureView(noise_texture);
    // proceed with simulation setup
}
```

No callbacks, no special async patterns. Same polling model as audio.

---

### Phase 5: Particle Life Example Project

**Directory: `examples/particle-life/`**

```
examples/particle-life/
  build.zig           -- wasm32-freestanding target, depends on zunk
  build.zig.zon       -- declares zunk dependency
  assets/
    blue-noise.png    -- copied from ref project
  src/
    main.zig          -- WASM exports (init, frame, resize), simulation orchestration
    particle.zig      -- data structures (Particle, Species, Force, SimulationOptions, CameraParams)
    shaders.zig       -- all WGSL as comptime strings
    simulation.zig    -- GPU resource management, render pipeline setup
    spatial.zig       -- spatial binning, prefix sum, sort, force computation
    system.zig        -- RNG, species colors, force matrix generation
```

**Porting strategy for each file:**

#### `main.zig`
Port from ref's `src/main.zig`. Key changes:
- Replace `@import("webgpu/...")` with `const gpu = @import("zunk").web.gpu`
- Replace `@import("webutils/webinputs.zig")` with `const input = @import("zunk").web.input`
- Replace `extern fn js_console_log` with `const app = @import("zunk").web.app`
- Replace custom exports (`setDevice`, `setBlueNoiseTexture`) with standard
  zunk lifecycle exports (`init`, `frame`, `resize`)
- Device handle obtained via `gpu.getDevice()` instead of explicit `setDevice` export
- Blue noise loaded via `asset.fetch()` + `gpu.createTextureFromAsset()` during init/frame
- Remove `setParticleCount`, `setSpeciesCount`, etc. (no UI in Phase 1 --
  hardcoded defaults)

Standard lifecycle mapping:
```
ref: init(seed)         -> zunk: init()    (seed from performanceNow or hardcoded)
ref: update(dt)         -> zunk: frame(dt)
ref: onResize(w, h)     -> zunk: resize(w, h)
```

#### `particle.zig`
Direct port. All `extern struct` definitions are pure Zig, no FFI dependency.
- Particle, Species, Force: unchanged
- SimulationOptions: unchanged (96 bytes extern struct)
- CameraParams: unchanged (32 bytes extern struct)
- `initForSimulation()`: unchanged

#### `shaders.zig`
Direct port. All WGSL shaders are comptime string literals, no FFI dependency.
- spatial_binning, prefix_sum, particle_sort, force_computation
- particle_advance, particle_init
- particle_render_glow, particle_render_circle, particle_render_point_hdr
- compose_shader

No changes needed -- these are pure data.

#### `simulation.zig`
The heaviest port. Replace all direct FFI calls with `gpu.*` API calls.

Before (ref):
```zig
const handles = @import("../webgpu/handles.zig");
const buffer = @import("../webgpu/buffer.zig");
// ...
self.particle_buffer = buffer.createStorageBuffer(size);
```

After (zunk):
```zig
const gpu = @import("zunk").web.gpu;
// ...
self.particle_buffer = gpu.createStorageBuffer(size);
```

Before (ref, render):
```zig
extern fn js_webgpu_begin_render_pass_hdr(...) u32;
const hdr_pass = js_webgpu_begin_render_pass_hdr(self.hdr_texture_view.handle.id, ...);
js_webgpu_render_pass_set_bind_group(hdr_pass, 0, self.particle_bind_group.handle.id);
```

After (zunk):
```zig
const hdr_pass = gpu.beginRenderPassHDR(self.hdr_texture_view, 0.001, 0.001, 0.001, 0.0);
gpu.renderPassSetBindGroup(hdr_pass, 0, self.particle_bind_group);
```

Key simplification: no more `.handle.id` unwrapping -- handles are already the
right type.

Handle type changes:
```
handles.RenderPipelineHandle  -> gpu.RenderPipeline (= bind.Handle)
handles.BufferHandle          -> gpu.Buffer (= bind.Handle)
buffer.Buffer                 -> struct { handle: gpu.Buffer, size: u64 }
```

We keep a local `BufferInfo` struct in the example project for tracking buffer
size alongside the handle (useful for bind group creation):
```zig
const BufferInfo = struct {
    handle: gpu.Buffer,
    size: u64,
};
```

#### `spatial.zig`
Port from ref. Same pattern: replace all `@import("../webgpu/...")` with
`gpu.*` calls. The algorithmic structure is identical.

Replace:
```zig
const encoder = compute.CommandEncoder.create();
```
With:
```zig
const encoder = gpu.createCommandEncoder();
```

Replace:
```zig
js_webgpu_compute_pass_set_bind_group_with_offset(pass_id, 0, group_id, offset);
```
With:
```zig
gpu.computePassSetBindGroupWithOffset(pass, 0, group, offset);
```

#### `system.zig`
Direct port. Pure Zig math (splitmix32 RNG, HSV color generation, force matrix).
No FFI dependency.

---

### Phase 6: Build System Integration

**`examples/particle-life/build.zig`:**
Same structure as `examples/input-demo/build.zig`:
```zig
const zunk = @import("zunk");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "particle-life",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zunk", b.dependency("zunk", .{}).module("zunk"));

    zunk.installApp(b, exe, .{});
}
```

**Asset handling:**
Already solved. The build tool automatically copies `src/assets/` to
`dist/assets/` during build. Place `blue-noise.png` in
`examples/particle-life/src/assets/` and reference it as
`"assets/blue-noise.png"` in Zig code. No build.zig changes needed.

---

## Dependency Graph

```
Phase 1 (gpu.zig)
    |
    +--> Phase 2 (resolver) --+--> Phase 3 (generator)
    |                         |
    |                         +--> Phase 4 (gpu texture from asset -- small, 2 externs)
    |
    +--> Phase 5 (particle life example)
              |
              +--> depends on Phases 2, 3, 4
              |
              +--> Phase 6 (build system -- asset copying already done)
```

Phase 1 and 2 can be developed in parallel (Zig API + JS resolver).
Phase 3 depends on Phase 2 (generator uses resolver outputs).
Phase 4 is now small (2 externs + 2 JS resolver entries); depends on Phase 2.
Phase 5 depends on all previous phases.
Phase 6 is simplified -- asset copying is already implemented.

---

## Testing Strategy

### Unit tests (in zunk core)
- `gpu.zig`: refAllDecls test (ensures compilation), BindGroupLayoutEntry and
  BindGroupEntry byte layout tests (verify extern struct packing matches JS DataView)
- `js_resolve.zig`: add tests for new WebGPU method resolution (create_buffer,
  begin_compute_pass, etc.)
- `js_gen.zig`: test that WebGPU feature detection triggers init code emission

### Integration test
- Build the particle-life example to WASM (`zig build`)
- Run `zunk build --wasm particle-life.wasm --output-dir dist/`
- Verify generated JS contains WebGPU init, handle table, all resolved imports
- Verify generated HTML has canvas element
- Verify resolution report shows 0 stubs

### Manual test
- `zunk run` the particle-life example
- Open browser, verify WebGPU initialization
- Verify particles render with HDR + tone mapping
- Verify mouse interaction (attract/repel, pan, zoom)
- Verify resize handling

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Struct packing mismatch (Zig extern struct vs JS DataView) | Medium | High | Byte-level unit tests for all struct layouts |
| WebGPU API differences across browsers | Low | Medium | Test on Chrome (primary), Firefox |
| Async texture loading race condition | Low | Medium | Polling pattern (asset.isReady + gpu.isTextureReady) prevents races by design |
| Generated JS too large | Low | Low | Only emit WebGPU init when category detected |
| WASM stack overflow (large local arrays in simulation) | Medium | High | Set explicit stack size in build.zig (ref project had this) |

---

## Estimated Scope

| Phase | New/Changed Files | Estimated Lines |
|-------|-------------------|----------------|
| 1. gpu.zig | 1 new, 1 modified (root.zig) | ~300 |
| 2. Resolver | 1 modified (js_resolve.zig) | ~200 (replace ~20, add ~180) |
| 3. Generator | 1 modified (js_gen.zig) | ~60 |
| 4. GPU texture from asset | 2 modified (gpu.zig, js_resolve.zig) | ~15 |
| 5. Particle life | 6 new files | ~1200 (ported from ~1400 in ref) |
| 6. Build system | 2 new files | ~60 |
| **Total** | ~10 new, ~4 modified | ~1850 |

---

## Open Questions

1. **Device handle as arg vs global**: Should `gpu.createBuffer()` take a device
   argument or use a global? The ref project uses a global device singleton.
   Recommendation: global (simpler API, single-device apps are the 99% case).

2. **HDR format enum or u32**: Should the render pipeline HDR format be an enum
   or raw u32? Recommendation: enum (TextureFormat) for type safety, with
   `@intFromEnum` at FFI boundary.

3. **Shared command encoder for render**: The ref uses a module-level JS variable
   `commandEncoder` shared between HDR pass and screen pass. Should the Zig API
   expose this or hide it? Recommendation: expose explicit encoder create/finish
   for compute, but keep the shared encoder for render passes implicit (handled
   in JS). The `present()` call finalizes everything.

4. **Do we want the input-demo pattern or something richer?** The input-demo uses
   standard zunk lifecycle (init/frame/resize). The particle life adds custom
   exports. Should we keep to the standard pattern? Recommendation: yes, standard
   pattern only. Configuration that the ref project did via custom exports
   (setParticleCount, etc.) is hardcoded in the Zig code for Phase 1.

---

## Implementation Status

All six phases are complete. The particle-life example is running.

### Post-implementation fixes (2026-02-28)

Three bugs found during testing, all fixed:

**1. Mouse DPR offset** (`src/gen/js_gen.zig` -- `emitInputSystem`)

Mouse `offsetX/offsetY` are CSS pixels, but the WebGPU resize handler passes
canvas buffer pixels (`clientWidth * DPR`) to `exports.resize()`. The simulation
divided mouse coords by buffer dimensions, causing the interaction point to be
off by the DPR factor (e.g. mapped to center quadrant on 2x displays).

Fix: scale mouse coords by `canvas.width / canvas.clientWidth` in the mousemove
handler. This ratio is naturally 1.0 for Canvas2D (no DPR scaling) and equals
DPR for WebGPU, so it works for both paths without branching. Also fixed a
zero-value bug (`offsetX || clientX` -> `offsetX ?? clientX`).

**2. Initial resize lost** (`examples/particle-life/src/main.zig`)

JS calls `exports.resize()` before the simulation exists (it's created lazily in
the first `frame()`), so the initial canvas dimensions were silently dropped.
The simulation initialized with hardcoded 1024x768, causing wrong HDR texture
size and camera until the user manually resized the window.

Fix: buffer pending resize dimensions in `main.zig`, apply after sim init.

**3. No DPR change detection** (`src/gen/js_gen.zig` -- WebGPU resize handler)

Moving the browser between monitors with different DPI triggered no resize.

Fix: added recursive `matchMedia` DPR watcher (one-shot listener pattern) in
the WebGPU resize handler path.

### Known issues (not yet addressed)

- **Touch coordinates** use viewport-relative `clientX/clientY` (not
  canvas-relative, not DPR-scaled). Should be addressed when touch support
  matures.
- **input-demo dist** has a stale render loop pattern (calls `zunkInput.flush()`
  in the JS frame loop AND Zig calls `input.poll()` which flushes again).
  Harmless double-flush, but inconsistent with the particle-life output.
