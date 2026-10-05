//! WebGPU bindings. Every `extern "env" fn zunk_gpu_*` below is resolved to a
//! JS snippet by `gen/js_resolve.zig` (`genWebGPU`); multi-line logic lives in
//! the `zunkGPU` helper object emitted by `gen/js_gen.zig` (`emitWebGPUState`).
//!
//! ## Handle lifecycle
//!
//! Every GPU object crosses the boundary as a `bind.Handle`: an index into a JS
//! table. Handle 0 is "none"; handle 1 is the GPUDevice.
//!   - Created by a `create*` call, valid until its `destroy*` / `release` call.
//!   - Passes and command buffers are single-use: `renderPassEnd`,
//!     `computePassEnd`, `encoderFinish` and `queueSubmit` release the handle
//!     they consume, so per-frame use never grows the table.
//!   - The *frame encoder* (`frameEncoder`) and the *canvas view*
//!     (`canvasView`) are created lazily on first use in a frame and released
//!     by `present`. Do not keep either across `present`.
//!
//! ## Frame model
//!
//! `beginRenderPass*` records into the frame encoder; `present` finishes and
//! submits it. Compute work can use its own `createCommandEncoder` +
//! `queueSubmit`, or share the frame encoder. Offscreen passes
//! (`RenderPassDescriptor.color = view`) are recorded in the same encoder, so
//! a later pass in the same frame can sample their result.
//!
//! ## Async operations (poll, never block)
//!
//! The wasm side cannot await, so each async operation is a handle plus a
//! state that is polled from `frame`:
//!   - `createTextureFromAsset`: `isTextureReady(tex)` flips false -> true.
//!   - Buffer readback: `MapState` is idle -> pending (`bufferMapRead`) ->
//!     mapped (`bufferMapState`) -> idle (`bufferUnmap`); a failed map reports
//!     `.failed` until unmapped. `bufferMapRead` must come AFTER the `present`
//!     (or `queueSubmit`) that submitted the copy; see `Readback`, which wraps
//!     the whole sequence for texture readback.

const std = @import("std");
const bind = @import("../bind/bind.zig");

// Type aliases -- all bind.Handle underneath, but named for documentation.
pub const Device = bind.Handle;
pub const Buffer = bind.Handle;
pub const ShaderModule = bind.Handle;
pub const Texture = bind.Handle;
pub const TextureView = bind.Handle;
pub const Sampler = bind.Handle;
pub const BindGroupLayout = bind.Handle;
pub const BindGroup = bind.Handle;
pub const PipelineLayout = bind.Handle;
pub const ComputePipeline = bind.Handle;
pub const RenderPipeline = bind.Handle;
pub const CommandEncoder = bind.Handle;
pub const ComputePassEncoder = bind.Handle;
pub const RenderPassEncoder = bind.Handle;
pub const CommandBuffer = bind.Handle;

// Usage flag constants (matching WebGPU GPUBufferUsage / GPUTextureUsage).
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

/// Index order is shared with the `textureFormats` table in js_gen.zig. Stencil
/// formats are deliberately absent: nothing here sets stencil ops, and a
/// stencil-bearing depth attachment would need them.
pub const TextureFormat = enum(u32) {
    rgba16float = 0,
    rgba32float = 1,
    bgra8unorm = 2,
    rgba8unorm = 3,
    rgba8unorm_srgb = 4,
    depth24plus = 5,
    depth32float = 6,
    r8unorm = 7,
};

pub const TextureSampleType = enum(u32) {
    float = 0,
    unfilterable_float = 1,
    depth = 2,
    sint = 3,
    uint = 4,
};

pub const SamplerBindingType = enum(u32) {
    filtering = 0,
    non_filtering = 1,
    comparison = 2,
};

pub const FilterMode = enum(u32) {
    nearest = 0,
    linear = 1,
};

pub const AddressMode = enum(u32) {
    clamp_to_edge = 0,
    repeat = 1,
    mirror_repeat = 2,
};

// 8 bytes, ABI-matched with JS DataView writer in js_resolve.zig.
pub const TextMetrics = extern struct {
    width: u32,
    height: u32,
};

// 24 bytes, ABI-matched with JS DataView reader in js_resolve.zig.
pub const SamplerDescriptor = extern struct {
    mag_filter: FilterMode = .nearest,
    min_filter: FilterMode = .nearest,
    address_u: AddressMode = .clamp_to_edge,
    address_v: AddressMode = .clamp_to_edge,
    address_w: AddressMode = .clamp_to_edge,
    _padding: u32 = 0,
};

pub const ShaderVisibility = struct {
    pub const VERTEX: u32 = 1;
    pub const FRAGMENT: u32 = 2;
    pub const COMPUTE: u32 = 4;
};

pub const BufferBindingType = enum(u32) {
    uniform = 0,
    storage = 1,
    read_only_storage = 2,
};

pub const VertexFormat = enum(u32) {
    float32 = 0,
    float32x2 = 1,
    float32x3 = 2,
    float32x4 = 3,
    uint32 = 4,
    uint32x2 = 5,
    uint32x3 = 6,
    uint32x4 = 7,
    sint32 = 8,
    sint32x2 = 9,
    sint32x3 = 10,
    sint32x4 = 11,
};

pub const VertexStepMode = enum(u32) {
    vertex = 0,
    instance = 1,
};

// 16 bytes, ABI-matched with JS DataView reader in js_resolve.zig
pub const VertexAttribute = extern struct {
    format: VertexFormat,
    offset: u32,
    shader_location: u32,
    _padding: u32 = 0,
};

// 16 bytes, ABI-matched with JS DataView reader in js_resolve.zig.
pub const VertexBufferLayout = extern struct {
    array_stride: u32,
    step_mode: VertexStepMode,
    attributes_ptr: u32,
    attributes_len: u32,

    pub fn fromSlice(
        stride: u32,
        step: VertexStepMode,
        attributes: []const VertexAttribute,
    ) VertexBufferLayout {
        return .{
            .array_stride = stride,
            .step_mode = step,
            .attributes_ptr = @intFromPtr(attributes.ptr),
            .attributes_len = @intCast(attributes.len),
        };
    }
};

// 40 bytes, ABI-matched with JS DataView reader in js_resolve.zig.
// Meaning of `type_variant` depends on `entry_type`:
//   entry_type == 0 (buffer)  -> BufferBindingType
//   entry_type == 1 (texture) -> TextureSampleType
//   entry_type == 2 (sampler) -> SamplerBindingType
pub const BindGroupLayoutEntry = extern struct {
    binding: u32,
    visibility: u32,
    entry_type: u32, // 0=buffer, 1=texture, 2=sampler
    type_variant: u32, // interpreted based on entry_type
    has_min_size: u32,
    has_dynamic_offset: u32,
    min_size: u64,
    _padding: u64 = 0,

    pub fn initBuffer(b: u32, vis: u32, buf_type: BufferBindingType) BindGroupLayoutEntry {
        return .{
            .binding = b,
            .visibility = vis,
            .entry_type = 0,
            .type_variant = @intFromEnum(buf_type),
            .has_min_size = 0,
            .has_dynamic_offset = 0,
            .min_size = 0,
        };
    }

    pub fn initTexture(b: u32, vis: u32, sample_type: TextureSampleType) BindGroupLayoutEntry {
        return .{
            .binding = b,
            .visibility = vis,
            .entry_type = 1,
            .type_variant = @intFromEnum(sample_type),
            .has_min_size = 0,
            .has_dynamic_offset = 0,
            .min_size = 0,
        };
    }

    pub fn initSampler(b: u32, vis: u32, sampler_type: SamplerBindingType) BindGroupLayoutEntry {
        return .{
            .binding = b,
            .visibility = vis,
            .entry_type = 2,
            .type_variant = @intFromEnum(sampler_type),
            .has_min_size = 0,
            .has_dynamic_offset = 0,
            .min_size = 0,
        };
    }

    pub fn withDynamicOffset(self: BindGroupLayoutEntry) BindGroupLayoutEntry {
        var entry = self;
        entry.has_dynamic_offset = 1;
        return entry;
    }

    pub fn withMinSize(self: BindGroupLayoutEntry, size: u64) BindGroupLayoutEntry {
        var entry = self;
        entry.has_min_size = 1;
        entry.min_size = size;
        return entry;
    }
};

// 32 bytes, ABI-matched with JS DataView reader in js_resolve.zig
pub const BindGroupEntry = extern struct {
    binding: u32,
    entry_type: u32, // 0=buffer, 1=texture_view, 2=sampler
    resource_handle: u32,
    _padding: u32 = 0,
    offset: u64,
    size: u64,

    pub fn initBuffer(b: u32, handle: bind.Handle, offset: u64, size: u64) BindGroupEntry {
        return .{
            .binding = b,
            .entry_type = 0,
            .resource_handle = @bitCast(handle.toInt()),
            .offset = offset,
            .size = size,
        };
    }

    pub fn initBufferFull(b: u32, handle: bind.Handle, size: u64) BindGroupEntry {
        return initBuffer(b, handle, 0, size);
    }

    pub fn initTextureView(b: u32, handle: bind.Handle) BindGroupEntry {
        return .{
            .binding = b,
            .entry_type = 1,
            .resource_handle = @bitCast(handle.toInt()),
            .offset = 0,
            .size = 0,
        };
    }

    pub fn initSampler(b: u32, handle: bind.Handle) BindGroupEntry {
        return .{
            .binding = b,
            .entry_type = 2,
            .resource_handle = @bitCast(handle.toInt()),
            .offset = 0,
            .size = 0,
        };
    }
};

pub const IndexFormat = enum(u32) {
    uint16 = 0,
    uint32 = 1,
};

pub const BlendMode = enum(u32) {
    /// Overwrite the target (opaque geometry).
    none = 0,
    /// Straight alpha: src*a + dst*(1-a).
    alpha = 1,
    /// Premultiplied alpha: src + dst*(1-a).
    premultiplied = 2,
    /// src*a + dst. Particles, glows.
    additive = 3,
};

pub const PrimitiveTopology = enum(u32) {
    triangle_list = 0,
    line_list = 1,
    line_strip = 2,
    triangle_strip = 3,
    point_list = 4,
};

pub const CullMode = enum(u32) {
    none = 0,
    front = 1,
    back = 2,
};

pub const FrontFace = enum(u32) {
    ccw = 0,
    cw = 1,
};

pub const CompareFunction = enum(u32) {
    never = 0,
    less = 1,
    equal = 2,
    less_equal = 3,
    greater = 4,
    not_equal = 5,
    greater_equal = 6,
    always = 7,
};

pub const LoadOp = enum(u32) {
    clear = 0,
    load = 1,
};

pub const StoreOp = enum(u32) {
    store = 0,
    discard = 1,
};

/// `Handle` 0 is "none" everywhere in this file.
const none_handle: u32 = 0;
/// Sentinel for "no format" in `RawPipelineDesc` (depth disabled / canvas colour).
const no_format: u32 = 0xFFFF_FFFF;

fn rawHandle(h: ?bind.Handle) u32 {
    return if (h) |x| @bitCast(x.toInt()) else none_handle;
}

/// A wasm32 linear-memory address as the u32 JS reads. Truncation is the
/// identity on wasm32; it only matters so host-side tests can lower
/// descriptors without a 64-bit pointer panicking.
fn ptr32(p: anytype) u32 {
    return @truncate(@intFromPtr(p));
}

pub const DepthState = struct {
    format: TextureFormat = .depth32float,
    write_enabled: bool = true,
    compare: CompareFunction = .less,
    /// Constant + slope-scaled depth bias; lets coplanar lines win against
    /// the faces they outline without touching the shader.
    bias: i32 = 0,
    bias_slope_scale: f32 = 0,
};

/// Everything a render pipeline needs. Defaults are "draw alpha-blended
/// triangles into the canvas, no depth, no MSAA", which is what the plain
/// `createRenderPipeline` does.
pub const RenderPipelineDescriptor = struct {
    layout: PipelineLayout,
    shader: ShaderModule,
    vertex_entry: []const u8,
    fragment_entry: []const u8,
    vertex_buffers: []const VertexBufferLayout = &.{},
    /// Colour target format; null = the canvas's preferred format (`canvasFormat`).
    color_format: ?TextureFormat = null,
    blend: BlendMode = .alpha,
    topology: PrimitiveTopology = .triangle_list,
    cull_mode: CullMode = .none,
    front_face: FrontFace = .ccw,
    /// null = no depth attachment is allowed in passes using this pipeline.
    depth: ?DepthState = null,
    /// Must equal the sample count of every attachment it renders into.
    sample_count: u32 = 1,

    pub fn raw(self: RenderPipelineDescriptor) RawPipelineDesc {
        const d = self.depth;
        return .{
            .layout = rawHandle(self.layout),
            .shader = rawHandle(self.shader),
            .vertex_entry_ptr = ptr32(self.vertex_entry.ptr),
            .vertex_entry_len = @intCast(self.vertex_entry.len),
            .fragment_entry_ptr = ptr32(self.fragment_entry.ptr),
            .fragment_entry_len = @intCast(self.fragment_entry.len),
            .vertex_buffers_ptr = ptr32(self.vertex_buffers.ptr),
            .vertex_buffers_len = @intCast(self.vertex_buffers.len),
            .color_format = if (self.color_format) |f| @intFromEnum(f) else no_format,
            .blend = @intFromEnum(self.blend),
            .topology = @intFromEnum(self.topology),
            .cull_mode = @intFromEnum(self.cull_mode),
            .front_face = @intFromEnum(self.front_face),
            .depth_format = if (d) |x| @intFromEnum(x.format) else no_format,
            .depth_write = if (d) |x| @intFromBool(x.write_enabled) else 0,
            .depth_compare = if (d) |x| @intFromEnum(x.compare) else @intFromEnum(CompareFunction.always),
            .depth_bias = if (d) |x| x.bias else 0,
            .depth_bias_slope = if (d) |x| x.bias_slope_scale else 0,
            .sample_count = self.sample_count,
        };
    }
};

/// 19 little-endian words, field order == `zunkGPU.createPipeline` in
/// js_gen.zig. Keep the two in lock-step.
pub const RawPipelineDesc = extern struct {
    layout: u32,
    shader: u32,
    vertex_entry_ptr: u32,
    vertex_entry_len: u32,
    fragment_entry_ptr: u32,
    fragment_entry_len: u32,
    vertex_buffers_ptr: u32,
    vertex_buffers_len: u32,
    color_format: u32,
    blend: u32,
    topology: u32,
    cull_mode: u32,
    front_face: u32,
    depth_format: u32,
    depth_write: u32,
    depth_compare: u32,
    depth_bias: i32,
    depth_bias_slope: f32,
    sample_count: u32,
};

/// One colour attachment (+ optional MSAA resolve, + optional depth).
pub const RenderPassDescriptor = struct {
    /// Colour target; null = the canvas's current texture (`canvasView`).
    color: ?TextureView = null,
    /// Single-sample view the MSAA `color` resolves into at pass end.
    resolve: ?TextureView = null,
    clear: [4]f32 = .{ 0, 0, 0, 1 },
    color_load: LoadOp = .clear,
    color_store: StoreOp = .store,
    depth: ?TextureView = null,
    depth_clear: f32 = 1.0,
    depth_load: LoadOp = .clear,
    depth_store: StoreOp = .store,

    pub fn raw(self: RenderPassDescriptor) RawPassDesc {
        return .{
            .color = rawHandle(self.color),
            .resolve = rawHandle(self.resolve),
            .depth = rawHandle(self.depth),
            .color_load = @intFromEnum(self.color_load),
            .color_store = @intFromEnum(self.color_store),
            .depth_load = @intFromEnum(self.depth_load),
            .depth_store = @intFromEnum(self.depth_store),
            .depth_clear = self.depth_clear,
            .clear = self.clear,
        };
    }
};

/// 12 little-endian words, field order == `zunkGPU.beginPass` in js_gen.zig.
pub const RawPassDesc = extern struct {
    color: u32,
    resolve: u32,
    depth: u32,
    color_load: u32,
    color_store: u32,
    depth_load: u32,
    depth_store: u32,
    depth_clear: f32,
    clear: [4]f32,
};

/// State of the (single) pending map on a buffer; see the module doc.
pub const MapState = enum(u32) {
    idle = 0,
    pending = 1,
    mapped = 2,
    failed = 3,
};

extern "env" fn zunk_gpu_release(handle: i32) void;
extern "env" fn zunk_gpu_canvas_format() u32;
extern "env" fn zunk_gpu_canvas_view() i32;
extern "env" fn zunk_gpu_canvas_size(out: *[2]u32) void;
extern "env" fn zunk_gpu_frame_encoder() i32;
extern "env" fn zunk_gpu_create_buffer(size: u32, usage: u32) i32;
extern "env" fn zunk_gpu_buffer_write(buffer_h: i32, offset: u32, data_ptr: [*]const u8, data_len: u32) void;
extern "env" fn zunk_gpu_buffer_destroy(buffer_h: i32) void;
extern "env" fn zunk_gpu_buffer_map_read(buffer_h: i32) void;
extern "env" fn zunk_gpu_buffer_map_state(buffer_h: i32) u32;
extern "env" fn zunk_gpu_buffer_read_mapped(buffer_h: i32, dst_ptr: [*]u8, len: u32) void;
extern "env" fn zunk_gpu_buffer_unmap(buffer_h: i32) void;
extern "env" fn zunk_gpu_copy_buffer_in_encoder(encoder_h: i32, src: i32, src_off: u32, dst: i32, dst_off: u32, size: u32) void;
extern "env" fn zunk_gpu_copy_texture_to_buffer(encoder_h: i32, texture_h: i32, buffer_h: i32, bytes_per_row: u32, width: u32, height: u32) void;
extern "env" fn zunk_gpu_create_shader_module(source_ptr: [*]const u8, source_len: u32) i32;
extern "env" fn zunk_gpu_create_texture(width: u32, height: u32, format: u32, usage: u32, sample_count: u32) i32;
extern "env" fn zunk_gpu_create_texture_view(texture_h: i32) i32;
extern "env" fn zunk_gpu_destroy_texture(texture_h: i32) void;
extern "env" fn zunk_gpu_write_texture(texture_h: i32, data_ptr: [*]const u8, data_len: u32, bytes_per_row: u32, width: u32, height: u32) void;
extern "env" fn zunk_gpu_create_sampler(desc_ptr: [*]const u8) i32;
extern "env" fn zunk_gpu_destroy_sampler(sampler_h: i32) void;
extern "env" fn zunk_gpu_create_bind_group_layout(entries_ptr: [*]const u8, entries_len: u32) i32;
extern "env" fn zunk_gpu_create_bind_group(layout_h: i32, entries_ptr: [*]const u8, entries_len: u32) i32;
extern "env" fn zunk_gpu_create_pipeline_layout(layouts_ptr: [*]const u8, layouts_len: u32) i32;
extern "env" fn zunk_gpu_create_compute_pipeline(layout_h: i32, shader_h: i32, entry_ptr: [*]const u8, entry_len: u32) i32;
extern "env" fn zunk_gpu_create_render_pipeline(desc_ptr: *const RawPipelineDesc) i32;
extern "env" fn zunk_gpu_create_command_encoder() i32;
extern "env" fn zunk_gpu_begin_compute_pass(encoder_h: i32) i32;
extern "env" fn zunk_gpu_compute_pass_set_pipeline(pass_h: i32, pipeline_h: i32) void;
extern "env" fn zunk_gpu_compute_pass_set_bind_group(pass_h: i32, index: u32, group_h: i32) void;
extern "env" fn zunk_gpu_compute_pass_set_bind_group_offset(pass_h: i32, index: u32, group_h: i32, offset: u32) void;
extern "env" fn zunk_gpu_compute_pass_dispatch(pass_h: i32, x: u32, y: u32, z: u32) void;
extern "env" fn zunk_gpu_compute_pass_end(pass_h: i32) void;
extern "env" fn zunk_gpu_encoder_finish(encoder_h: i32) i32;
extern "env" fn zunk_gpu_queue_submit(cmd_buffer_h: i32) void;
extern "env" fn zunk_gpu_begin_render_pass(desc_ptr: *const RawPassDesc) i32;
extern "env" fn zunk_gpu_render_pass_set_pipeline(pass_h: i32, pipeline_h: i32) void;
extern "env" fn zunk_gpu_render_pass_set_bind_group(pass_h: i32, index: u32, group_h: i32) void;
extern "env" fn zunk_gpu_render_pass_set_vertex_buffer(pass_h: i32, slot: u32, buffer_h: i32, offset_lo: u32, offset_hi: u32, size_lo: u32, size_hi: u32) void;
extern "env" fn zunk_gpu_render_pass_set_index_buffer(pass_h: i32, buffer_h: i32, format: u32, offset_lo: u32, offset_hi: u32, size_lo: u32, size_hi: u32) void;
extern "env" fn zunk_gpu_render_pass_set_viewport(pass_h: i32, x: f32, y: f32, w: f32, h: f32, min_depth: f32, max_depth: f32) void;
extern "env" fn zunk_gpu_render_pass_set_scissor_rect(pass_h: i32, x: u32, y: u32, w: u32, h: u32) void;
extern "env" fn zunk_gpu_render_pass_draw(pass_h: i32, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void;
extern "env" fn zunk_gpu_render_pass_draw_indexed(pass_h: i32, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) void;
extern "env" fn zunk_gpu_render_pass_end(pass_h: i32) void;
extern "env" fn zunk_gpu_present() void;
extern "env" fn zunk_gpu_create_texture_from_asset(asset_h: i32) i32;
extern "env" fn zunk_gpu_is_texture_ready(handle: i32) i32;
extern "env" fn zunk_gpu_measure_text(
    text_ptr: [*]const u8,
    text_len: u32,
    font_ptr: [*]const u8,
    font_len: u32,
    out_ptr: *TextMetrics,
    letter_spacing: f32,
) void;
extern "env" fn zunk_gpu_rasterize_text(
    text_ptr: [*]const u8,
    text_len: u32,
    font_ptr: [*]const u8,
    font_len: u32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    width: u32,
    height: u32,
    letter_spacing: f32,
) i32;

pub fn getDevice() Device {
    return bind.Handle.fromInt(1);
}

/// Drop the JS-side reference to any handle. Only needed for objects without
/// a dedicated `destroy*` (views, bind groups, pipelines, layouts).
pub fn release(handle: bind.Handle) void {
    zunk_gpu_release(handle.toInt());
}

/// The swap-chain format the canvas was configured with. MSAA colour targets
/// that resolve into the canvas must use this format.
pub fn canvasFormat() TextureFormat {
    return @enumFromInt(zunk_gpu_canvas_format());
}

/// Pixel size of the canvas's swap-chain texture (CSS size x devicePixelRatio).
/// Multisampled / depth targets that resolve into or accompany the canvas
/// must match it exactly.
pub fn canvasSize() struct { w: u32, h: u32 } {
    var wh: [2]u32 = .{ 0, 0 };
    zunk_gpu_canvas_size(&wh);
    return .{ .w = wh[0], .h = wh[1] };
}

/// View of the canvas's current texture. Created on first call in a frame and
/// released by `present`; do not keep it across frames.
pub fn canvasView() TextureView {
    return bind.Handle.fromInt(zunk_gpu_canvas_view());
}

/// The encoder `beginRenderPass*` records into, created on first use in a
/// frame and submitted by `present`. Use it for `copyTextureToBuffer`,
/// `copyBufferInEncoder` or `beginComputePass` work that must be ordered
/// with the frame's render passes.
pub fn frameEncoder() CommandEncoder {
    return bind.Handle.fromInt(zunk_gpu_frame_encoder());
}

pub fn createBuffer(size: u32, usage: u32) Buffer {
    return bind.Handle.fromInt(zunk_gpu_create_buffer(size, usage));
}

pub fn createStorageBuffer(size: u32) Buffer {
    return createBuffer(size, BufferUsage.STORAGE | BufferUsage.COPY_DST | BufferUsage.COPY_SRC);
}

pub fn createUniformBuffer(size: u32) Buffer {
    return createBuffer(size, BufferUsage.UNIFORM | BufferUsage.COPY_DST);
}

pub fn bufferWrite(buf: Buffer, offset: u32, data: []const u8) void {
    zunk_gpu_buffer_write(buf.toInt(), offset, data.ptr, @intCast(data.len));
}

pub fn bufferWriteTyped(comptime T: type, buf: Buffer, offset: u32, items: []const T) void {
    bufferWrite(buf, offset, std.mem.sliceAsBytes(items));
}

pub fn bufferDestroy(buf: Buffer) void {
    zunk_gpu_buffer_destroy(buf.toInt());
}

/// Start mapping `buf` (MAP_READ usage) for reading. Poll `bufferMapState`;
/// call only after the work that fills the buffer has been submitted.
pub fn bufferMapRead(buf: Buffer) void {
    zunk_gpu_buffer_map_read(buf.toInt());
}

pub fn bufferMapState(buf: Buffer) MapState {
    return @enumFromInt(zunk_gpu_buffer_map_state(buf.toInt()));
}

/// Copy `dst.len` bytes of a `.mapped` buffer into wasm memory.
pub fn bufferReadMapped(buf: Buffer, dst: []u8) void {
    zunk_gpu_buffer_read_mapped(buf.toInt(), dst.ptr, @intCast(dst.len));
}

/// End a map (successful or failed) and return the buffer to `.idle`.
pub fn bufferUnmap(buf: Buffer) void {
    zunk_gpu_buffer_unmap(buf.toInt());
}

pub fn copyBufferInEncoder(encoder: CommandEncoder, src: Buffer, src_off: u32, dst: Buffer, dst_off: u32, size: u32) void {
    zunk_gpu_copy_buffer_in_encoder(encoder.toInt(), src.toInt(), src_off, dst.toInt(), dst_off, size);
}

pub fn createShaderModule(source: []const u8) ShaderModule {
    return bind.Handle.fromInt(zunk_gpu_create_shader_module(source.ptr, @intCast(source.len)));
}

pub fn createTexture(w: u32, h: u32, fmt: TextureFormat, usage: u32) Texture {
    return createTextureMultisampled(w, h, fmt, usage, 1);
}

/// `sample_count` 1 or 4. A multisampled texture can only be a render
/// attachment (`RENDER_ATTACHMENT`); resolve it into a single-sample texture
/// to sample or read it.
pub fn createTextureMultisampled(w: u32, h: u32, fmt: TextureFormat, usage: u32, sample_count: u32) Texture {
    return bind.Handle.fromInt(zunk_gpu_create_texture(w, h, @intFromEnum(fmt), usage, sample_count));
}

/// A depth buffer matching a colour target's size and sample count.
pub fn createDepthTexture(w: u32, h: u32, fmt: TextureFormat, sample_count: u32) Texture {
    std.debug.assert(fmt == .depth24plus or fmt == .depth32float);
    return createTextureMultisampled(w, h, fmt, TextureUsage.RENDER_ATTACHMENT, sample_count);
}

/// A colour texture that can be rendered into and then sampled / copied out.
pub fn createRenderTarget(w: u32, h: u32, fmt: TextureFormat) Texture {
    return createTexture(w, h, fmt, TextureUsage.RENDER_ATTACHMENT | TextureUsage.TEXTURE_BINDING | TextureUsage.COPY_SRC);
}

pub fn createTextureView(tex: Texture) TextureView {
    return bind.Handle.fromInt(zunk_gpu_create_texture_view(tex.toInt()));
}

pub fn destroyTexture(tex: Texture) void {
    zunk_gpu_destroy_texture(tex.toInt());
}

/// Upload CPU bytes into `tex` at origin (0,0). `bytes_per_row` is the
/// stride of the source data in bytes (for tightly packed rgba8: width*4).
pub fn writeTexture(
    tex: Texture,
    bytes: []const u8,
    bytes_per_row: u32,
    width: u32,
    height: u32,
) void {
    zunk_gpu_write_texture(
        tex.toInt(),
        bytes.ptr,
        @intCast(bytes.len),
        bytes_per_row,
        width,
        height,
    );
}

pub fn createSampler(desc: SamplerDescriptor) Sampler {
    return bind.Handle.fromInt(zunk_gpu_create_sampler(@ptrCast(&desc)));
}

pub fn destroySampler(sampler: Sampler) void {
    zunk_gpu_destroy_sampler(sampler.toInt());
}

pub fn createHDRTexture(w: u32, h: u32) Texture {
    return createTexture(w, h, .rgba16float, TextureUsage.RENDER_ATTACHMENT | TextureUsage.TEXTURE_BINDING);
}

pub fn createBindGroupLayout(entries: []const BindGroupLayoutEntry) BindGroupLayout {
    return bind.Handle.fromInt(zunk_gpu_create_bind_group_layout(
        @ptrCast(entries.ptr),
        @intCast(entries.len),
    ));
}

pub fn createBindGroup(layout: BindGroupLayout, entries: []const BindGroupEntry) BindGroup {
    return bind.Handle.fromInt(zunk_gpu_create_bind_group(
        layout.toInt(),
        @ptrCast(entries.ptr),
        @intCast(entries.len),
    ));
}

pub fn createPipelineLayout(layouts: []const BindGroupLayout) PipelineLayout {
    return bind.Handle.fromInt(zunk_gpu_create_pipeline_layout(
        @ptrCast(layouts.ptr),
        @intCast(layouts.len),
    ));
}

pub fn createComputePipeline(layout: PipelineLayout, shader: ShaderModule, entry_point: []const u8) ComputePipeline {
    return bind.Handle.fromInt(zunk_gpu_create_compute_pipeline(
        layout.toInt(),
        shader.toInt(),
        entry_point.ptr,
        @intCast(entry_point.len),
    ));
}

pub fn createRenderPipelineDesc(desc: RenderPipelineDescriptor) RenderPipeline {
    const raw = desc.raw();
    return bind.Handle.fromInt(zunk_gpu_create_render_pipeline(&raw));
}

/// Alpha-blended triangle list into the canvas, no depth.
pub fn createRenderPipeline(
    layout: PipelineLayout,
    shader: ShaderModule,
    vertex_entry: []const u8,
    fragment_entry: []const u8,
    vertex_buffers: []const VertexBufferLayout,
) RenderPipeline {
    return createRenderPipelineDesc(.{
        .layout = layout,
        .shader = shader,
        .vertex_entry = vertex_entry,
        .fragment_entry = fragment_entry,
        .vertex_buffers = vertex_buffers,
    });
}

/// Triangle list into an offscreen `format` target; additive or no blending.
pub fn createRenderPipelineHDR(
    layout: PipelineLayout,
    shader: ShaderModule,
    vertex_entry: []const u8,
    fragment_entry: []const u8,
    format: TextureFormat,
    blending: bool,
    vertex_buffers: []const VertexBufferLayout,
) RenderPipeline {
    return createRenderPipelineDesc(.{
        .layout = layout,
        .shader = shader,
        .vertex_entry = vertex_entry,
        .fragment_entry = fragment_entry,
        .vertex_buffers = vertex_buffers,
        .color_format = format,
        .blend = if (blending) .additive else .none,
    });
}

pub fn createCommandEncoder() CommandEncoder {
    return bind.Handle.fromInt(zunk_gpu_create_command_encoder());
}

pub fn beginComputePass(encoder: CommandEncoder) ComputePassEncoder {
    return bind.Handle.fromInt(zunk_gpu_begin_compute_pass(encoder.toInt()));
}

pub fn computePassSetPipeline(pass: ComputePassEncoder, pip: ComputePipeline) void {
    zunk_gpu_compute_pass_set_pipeline(pass.toInt(), pip.toInt());
}

pub fn computePassSetBindGroup(pass: ComputePassEncoder, index: u32, group: BindGroup) void {
    zunk_gpu_compute_pass_set_bind_group(pass.toInt(), index, group.toInt());
}

pub fn computePassSetBindGroupWithOffset(pass: ComputePassEncoder, index: u32, group: BindGroup, offset: u32) void {
    zunk_gpu_compute_pass_set_bind_group_offset(pass.toInt(), index, group.toInt(), offset);
}

pub fn computePassDispatch(pass: ComputePassEncoder, x: u32, y: u32, z: u32) void {
    zunk_gpu_compute_pass_dispatch(pass.toInt(), x, y, z);
}

pub fn computePassEnd(pass: ComputePassEncoder) void {
    zunk_gpu_compute_pass_end(pass.toInt());
}

pub fn encoderFinish(encoder: CommandEncoder) CommandBuffer {
    return bind.Handle.fromInt(zunk_gpu_encoder_finish(encoder.toInt()));
}

pub fn queueSubmit(cmd: CommandBuffer) void {
    zunk_gpu_queue_submit(cmd.toInt());
}

pub fn beginRenderPassDesc(desc: RenderPassDescriptor) RenderPassEncoder {
    const raw = desc.raw();
    return bind.Handle.fromInt(zunk_gpu_begin_render_pass(&raw));
}

/// Clear the canvas to a colour and begin drawing into it.
pub fn beginRenderPass(r: f32, g: f32, b: f32, a: f32) RenderPassEncoder {
    return beginRenderPassDesc(.{ .clear = .{ r, g, b, a } });
}

/// Clear an offscreen view to a colour and begin drawing into it.
pub fn beginRenderPassHDR(view: TextureView, r: f32, g: f32, b: f32, a: f32) RenderPassEncoder {
    return beginRenderPassDesc(.{ .color = view, .clear = .{ r, g, b, a } });
}

pub fn renderPassSetPipeline(pass: RenderPassEncoder, pip: RenderPipeline) void {
    zunk_gpu_render_pass_set_pipeline(pass.toInt(), pip.toInt());
}

pub fn renderPassSetBindGroup(pass: RenderPassEncoder, index: u32, group: BindGroup) void {
    zunk_gpu_render_pass_set_bind_group(pass.toInt(), index, group.toInt());
}

pub fn renderPassSetVertexBuffer(pass: RenderPassEncoder, slot: u32, buffer: Buffer, offset: u64, size: u64) void {
    zunk_gpu_render_pass_set_vertex_buffer(
        pass.toInt(),
        slot,
        buffer.toInt(),
        @truncate(offset),
        @truncate(offset >> 32),
        @truncate(size),
        @truncate(size >> 32),
    );
}

pub fn renderPassSetIndexBuffer(pass: RenderPassEncoder, buffer: Buffer, format: IndexFormat, offset: u64, size: u64) void {
    zunk_gpu_render_pass_set_index_buffer(
        pass.toInt(),
        buffer.toInt(),
        @intFromEnum(format),
        @truncate(offset),
        @truncate(offset >> 32),
        @truncate(size),
        @truncate(size >> 32),
    );
}

/// Viewport in target pixels; depth range is normally 0..1.
pub fn renderPassSetViewport(pass: RenderPassEncoder, x: f32, y: f32, w: f32, h: f32, min_depth: f32, max_depth: f32) void {
    zunk_gpu_render_pass_set_viewport(pass.toInt(), x, y, w, h, min_depth, max_depth);
}

pub fn renderPassSetScissorRect(pass: RenderPassEncoder, x: u32, y: u32, w: u32, h: u32) void {
    zunk_gpu_render_pass_set_scissor_rect(pass.toInt(), x, y, w, h);
}

/// `instance_count > 1` repeats the draw; vertex buffers whose layout has
/// `step_mode = .instance` advance once per instance instead of per vertex.
pub fn renderPassDraw(pass: RenderPassEncoder, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
    zunk_gpu_render_pass_draw(pass.toInt(), vertex_count, instance_count, first_vertex, first_instance);
}

pub fn renderPassDrawIndexed(pass: RenderPassEncoder, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
    zunk_gpu_render_pass_draw_indexed(pass.toInt(), index_count, instance_count, first_index, base_vertex, first_instance);
}

pub fn renderPassEnd(pass: RenderPassEncoder) void {
    zunk_gpu_render_pass_end(pass.toInt());
}

/// Record a copy of `texture` (COPY_SRC) into `buffer` (COPY_DST).
/// `bytes_per_row` must be a multiple of 256 (`Readback` handles this).
pub fn copyTextureToBuffer(encoder: CommandEncoder, texture: Texture, buffer: Buffer, bytes_per_row: u32, width: u32, height: u32) void {
    zunk_gpu_copy_texture_to_buffer(encoder.toInt(), texture.toInt(), buffer.toInt(), bytes_per_row, width, height);
}

/// Finish and submit the frame encoder, then release the canvas view.
pub fn present() void {
    zunk_gpu_present();
}

pub fn createTextureFromAsset(asset_handle: bind.Handle) Texture {
    return bind.Handle.fromInt(zunk_gpu_create_texture_from_asset(asset_handle.toInt()));
}

pub fn isTextureReady(handle: Texture) bool {
    return zunk_gpu_is_texture_ready(handle.toInt()) != 0;
}

/// Measure a text run in pixels using the browser's canvas 2D text shaper.
/// `font` is a CSS font string, e.g. "500 14px monospace"; `letter_spacing` is
/// the extra advance after every glyph in px (canvas `letterSpacing`).
pub fn measureText(text: []const u8, font: []const u8, letter_spacing: f32) TextMetrics {
    var out: TextMetrics = .{ .width = 0, .height = 0 };
    zunk_gpu_measure_text(
        text.ptr,
        @intCast(text.len),
        font.ptr,
        @intCast(font.len),
        &out,
        letter_spacing,
    );
    return out;
}

/// Rasterize `text` into a freshly allocated rgba8unorm `Texture` of the given
/// size, using the browser's canvas 2D text shaper. `color` is the foreground
/// fill (0..1 RGBA). The texture has `TEXTURE_BINDING | COPY_DST` usage and is
/// ready to bind in the same frame. `font` and `letter_spacing` as in
/// `measureText`.
pub fn rasterizeText(
    text: []const u8,
    font: []const u8,
    letter_spacing: f32,
    color: [4]f32,
    width: u32,
    height: u32,
) Texture {
    return bind.Handle.fromInt(zunk_gpu_rasterize_text(
        text.ptr,
        @intCast(text.len),
        font.ptr,
        @intCast(font.len),
        color[0],
        color[1],
        color[2],
        color[3],
        width,
        height,
        letter_spacing,
    ));
}

/// Texture -> CPU readback, for headless pixel tests and screenshots of
/// offscreen targets. Usage, in order, across frames:
///
///     var rb = Readback.init(w, h, 4);
///     rb.encode(gpu.frameEncoder(), target);   // while recording the frame
///     gpu.present();
///     rb.request();                            // after the submit
///     ...                                      // later frames: poll()
///     if (rb.poll() == .mapped) rb.read(buf);  // buf.len >= rb.paddedSize()
///
/// Rows in `buf` are `bytes_per_row` apart (padded to 256), not `w * bpp`.
pub const Readback = struct {
    buffer: Buffer,
    width: u32,
    height: u32,
    bytes_per_row: u32,

    pub fn init(width: u32, height: u32, bytes_per_pixel: u32) Readback {
        const bpr = alignRow(width * bytes_per_pixel);
        return .{
            .buffer = createBuffer(bpr * height, BufferUsage.MAP_READ | BufferUsage.COPY_DST),
            .width = width,
            .height = height,
            .bytes_per_row = bpr,
        };
    }

    pub fn deinit(self: Readback) void {
        bufferDestroy(self.buffer);
    }

    pub fn paddedSize(self: Readback) u32 {
        return self.bytes_per_row * self.height;
    }

    pub fn encode(self: Readback, encoder: CommandEncoder, texture: Texture) void {
        copyTextureToBuffer(encoder, texture, self.buffer, self.bytes_per_row, self.width, self.height);
    }

    pub fn request(self: Readback) void {
        bufferMapRead(self.buffer);
    }

    pub fn poll(self: Readback) MapState {
        return bufferMapState(self.buffer);
    }

    /// Copy out and unmap; the Readback can be reused for another capture.
    pub fn read(self: Readback, dst: []u8) void {
        bufferReadMapped(self.buffer, dst[0..self.paddedSize()]);
        bufferUnmap(self.buffer);
    }

    /// RGBA/BGRA pixel at (x, y) of a buffer filled by `read`.
    pub fn pixel(self: Readback, data: []const u8, x: u32, y: u32) [4]u8 {
        const o = y * self.bytes_per_row + x * 4;
        return data[o..][0..4].*;
    }
};

/// WebGPU requires `bytesPerRow` of texture copies to be a multiple of 256.
pub fn alignRow(bytes: u32) u32 {
    return (bytes + 255) & ~@as(u32, 255);
}

test "struct layout RawPipelineDesc" {
    try std.testing.expectEqual(@as(usize, 19 * 4), @sizeOf(RawPipelineDesc));
}

test "struct layout RawPassDesc" {
    try std.testing.expectEqual(@as(usize, 12 * 4), @sizeOf(RawPassDesc));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(RawPassDesc, "clear"));
}

test "alignRow pads to 256" {
    try std.testing.expectEqual(@as(u32, 256), alignRow(4));
    try std.testing.expectEqual(@as(u32, 256), alignRow(256));
    try std.testing.expectEqual(@as(u32, 512), alignRow(257));
    try std.testing.expectEqual(@as(u32, 1024), alignRow(1000));
}

test "RenderPassDescriptor lowers null views to handle 0" {
    const r = (RenderPassDescriptor{}).raw();
    try std.testing.expectEqual(@as(u32, 0), r.color);
    try std.testing.expectEqual(@as(u32, 0), r.depth);
    try std.testing.expectEqual(@as(f32, 1.0), r.depth_clear);

    const d = (RenderPassDescriptor{
        .color = bind.Handle.fromInt(7),
        .resolve = bind.Handle.fromInt(8),
        .depth = bind.Handle.fromInt(9),
        .color_store = .discard,
        .depth_load = .load,
    }).raw();
    try std.testing.expectEqual(@as(u32, 7), d.color);
    try std.testing.expectEqual(@as(u32, 8), d.resolve);
    try std.testing.expectEqual(@as(u32, 9), d.depth);
    try std.testing.expectEqual(@as(u32, 1), d.color_store);
    try std.testing.expectEqual(@as(u32, 1), d.depth_load);
}

test "RenderPipelineDescriptor lowering: instanced vertex layout, depth, msaa" {
    const attrs = [_]VertexAttribute{.{ .format = .float32x3, .offset = 0, .shader_location = 0 }};
    const layouts = [_]VertexBufferLayout{
        VertexBufferLayout.fromSlice(12, .vertex, &attrs),
        VertexBufferLayout.fromSlice(12, .instance, &attrs),
    };
    try std.testing.expectEqual(VertexStepMode.instance, layouts[1].step_mode);

    const raw = (RenderPipelineDescriptor{
        .layout = bind.Handle.fromInt(2),
        .shader = bind.Handle.fromInt(3),
        .vertex_entry = "vs",
        .fragment_entry = "fs",
        .vertex_buffers = &layouts,
        .color_format = .rgba8unorm,
        .blend = .none,
        .topology = .line_list,
        .cull_mode = .back,
        .depth = .{ .format = .depth24plus, .compare = .less_equal, .write_enabled = false, .bias = -2 },
        .sample_count = 4,
    }).raw();
    try std.testing.expectEqual(@as(u32, 2), raw.vertex_buffers_len);
    try std.testing.expectEqual(@as(u32, @intFromEnum(TextureFormat.rgba8unorm)), raw.color_format);
    try std.testing.expectEqual(@as(u32, @intFromEnum(PrimitiveTopology.line_list)), raw.topology);
    try std.testing.expectEqual(@as(u32, @intFromEnum(TextureFormat.depth24plus)), raw.depth_format);
    try std.testing.expectEqual(@as(u32, 0), raw.depth_write);
    try std.testing.expectEqual(@as(i32, -2), raw.depth_bias);
    try std.testing.expectEqual(@as(u32, 4), raw.sample_count);

    // Defaults: canvas format, no depth, single sample.
    const plain = (RenderPipelineDescriptor{
        .layout = bind.Handle.fromInt(2),
        .shader = bind.Handle.fromInt(3),
        .vertex_entry = "vs",
        .fragment_entry = "fs",
    }).raw();
    try std.testing.expectEqual(no_format, plain.color_format);
    try std.testing.expectEqual(no_format, plain.depth_format);
    try std.testing.expectEqual(@as(u32, 1), plain.sample_count);
}

test "struct layout BindGroupLayoutEntry" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(BindGroupLayoutEntry));
}

test "struct layout BindGroupEntry" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(BindGroupEntry));
}

test "struct layout VertexAttribute" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(VertexAttribute));
}

test "struct layout VertexBufferLayout" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(VertexBufferLayout));
}

test "struct layout SamplerDescriptor" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(SamplerDescriptor));
}

test "struct layout TextMetrics" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(TextMetrics));
}

test "BindGroupLayoutEntry initSampler encodes type_variant" {
    const e = BindGroupLayoutEntry.initSampler(3, ShaderVisibility.FRAGMENT, .filtering);
    try std.testing.expectEqual(@as(u32, 2), e.entry_type);
    try std.testing.expectEqual(@as(u32, 0), e.type_variant);
}

test "BindGroupEntry initSampler encodes entry_type=2" {
    const h = bind.Handle.fromInt(42);
    const e = BindGroupEntry.initSampler(1, h);
    try std.testing.expectEqual(@as(u32, 2), e.entry_type);
    try std.testing.expectEqual(@as(u32, 42), e.resource_handle);
}

test {
    std.testing.refAllDecls(@This());
}
