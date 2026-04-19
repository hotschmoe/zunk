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
    mag_filter: u32 = 0, // FilterMode
    min_filter: u32 = 0, // FilterMode
    address_u: u32 = 0, // AddressMode
    address_v: u32 = 0, // AddressMode
    address_w: u32 = 0, // AddressMode
    _padding: u32 = 0,

    pub fn init(
        mag: FilterMode,
        min: FilterMode,
        u: AddressMode,
        v: AddressMode,
    ) SamplerDescriptor {
        return .{
            .mag_filter = @intFromEnum(mag),
            .min_filter = @intFromEnum(min),
            .address_u = @intFromEnum(u),
            .address_v = @intFromEnum(v),
            .address_w = @intFromEnum(u),
        };
    }
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
    format: u32, // VertexFormat
    offset: u32,
    shader_location: u32,
    _padding: u32 = 0,

    pub fn init(loc: u32, format: VertexFormat, offset: u32) VertexAttribute {
        return .{
            .format = @intFromEnum(format),
            .offset = offset,
            .shader_location = loc,
        };
    }
};

// 16 bytes, ABI-matched with JS DataView reader in js_resolve.zig.
pub const VertexBufferLayout = extern struct {
    array_stride: u32,
    step_mode: u32, // VertexStepMode
    attributes_ptr: u32,
    attributes_len: u32,

    pub fn init(stride: u32, step: VertexStepMode, attributes: []const VertexAttribute) VertexBufferLayout {
        return .{
            .array_stride = stride,
            .step_mode = @intFromEnum(step),
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

extern "env" fn zunk_gpu_create_buffer(size: u32, usage: u32) i32;
extern "env" fn zunk_gpu_buffer_write(buffer_h: i32, offset: u32, data_ptr: [*]const u8, data_len: u32) void;
extern "env" fn zunk_gpu_buffer_destroy(buffer_h: i32) void;
extern "env" fn zunk_gpu_copy_buffer_in_encoder(encoder_h: i32, src: i32, src_off: u32, dst: i32, dst_off: u32, size: u32) void;
extern "env" fn zunk_gpu_create_shader_module(source_ptr: [*]const u8, source_len: u32) i32;
extern "env" fn zunk_gpu_create_texture(width: u32, height: u32, format: u32, usage: u32) i32;
extern "env" fn zunk_gpu_create_texture_view(texture_h: i32) i32;
extern "env" fn zunk_gpu_destroy_texture(texture_h: i32) void;
extern "env" fn zunk_gpu_write_texture(texture_h: i32, data_ptr: [*]const u8, data_len: u32, bytes_per_row: u32, width: u32, height: u32) void;
extern "env" fn zunk_gpu_create_sampler(desc_ptr: [*]const u8) i32;
extern "env" fn zunk_gpu_destroy_sampler(sampler_h: i32) void;
extern "env" fn zunk_gpu_create_bind_group_layout(entries_ptr: [*]const u8, entries_len: u32) i32;
extern "env" fn zunk_gpu_create_bind_group(layout_h: i32, entries_ptr: [*]const u8, entries_len: u32) i32;
extern "env" fn zunk_gpu_create_pipeline_layout(layouts_ptr: [*]const u8, layouts_len: u32) i32;
extern "env" fn zunk_gpu_create_compute_pipeline(layout_h: i32, shader_h: i32, entry_ptr: [*]const u8, entry_len: u32) i32;
extern "env" fn zunk_gpu_create_render_pipeline(layout_h: i32, shader_h: i32, vert_ptr: [*]const u8, vert_len: u32, frag_ptr: [*]const u8, frag_len: u32, vbuf_layouts_ptr: [*]const u8, vbuf_layouts_len: u32) i32;
extern "env" fn zunk_gpu_create_render_pipeline_hdr(layout_h: i32, shader_h: i32, vert_ptr: [*]const u8, vert_len: u32, frag_ptr: [*]const u8, frag_len: u32, format: u32, blending: u32, vbuf_layouts_ptr: [*]const u8, vbuf_layouts_len: u32) i32;
extern "env" fn zunk_gpu_create_command_encoder() i32;
extern "env" fn zunk_gpu_begin_compute_pass(encoder_h: i32) i32;
extern "env" fn zunk_gpu_compute_pass_set_pipeline(pass_h: i32, pipeline_h: i32) void;
extern "env" fn zunk_gpu_compute_pass_set_bind_group(pass_h: i32, index: u32, group_h: i32) void;
extern "env" fn zunk_gpu_compute_pass_set_bind_group_offset(pass_h: i32, index: u32, group_h: i32, offset: u32) void;
extern "env" fn zunk_gpu_compute_pass_dispatch(pass_h: i32, x: u32, y: u32, z: u32) void;
extern "env" fn zunk_gpu_compute_pass_end(pass_h: i32) void;
extern "env" fn zunk_gpu_encoder_finish(encoder_h: i32) i32;
extern "env" fn zunk_gpu_queue_submit(cmd_buffer_h: i32) void;
extern "env" fn zunk_gpu_begin_render_pass(r: f32, g: f32, b: f32, a: f32) i32;
extern "env" fn zunk_gpu_begin_render_pass_hdr(texture_view_h: i32, r: f32, g: f32, b: f32, a: f32) i32;
extern "env" fn zunk_gpu_render_pass_set_pipeline(pass_h: i32, pipeline_h: i32) void;
extern "env" fn zunk_gpu_render_pass_set_bind_group(pass_h: i32, index: u32, group_h: i32) void;
extern "env" fn zunk_gpu_render_pass_set_vertex_buffer(pass_h: i32, slot: u32, buffer_h: i32, offset_lo: u32, offset_hi: u32, size_lo: u32, size_hi: u32) void;
extern "env" fn zunk_gpu_render_pass_draw(pass_h: i32, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void;
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
) i32;

pub fn getDevice() Device {
    return bind.Handle.fromInt(1);
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

pub fn copyBufferInEncoder(encoder: CommandEncoder, src: Buffer, src_off: u32, dst: Buffer, dst_off: u32, size: u32) void {
    zunk_gpu_copy_buffer_in_encoder(encoder.toInt(), src.toInt(), src_off, dst.toInt(), dst_off, size);
}

pub fn createShaderModule(source: []const u8) ShaderModule {
    return bind.Handle.fromInt(zunk_gpu_create_shader_module(source.ptr, @intCast(source.len)));
}

pub fn createTexture(w: u32, h: u32, fmt: TextureFormat, usage: u32) Texture {
    return bind.Handle.fromInt(zunk_gpu_create_texture(w, h, @intFromEnum(fmt), usage));
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

pub fn createRenderPipeline(
    layout: PipelineLayout,
    shader: ShaderModule,
    vertex_entry: []const u8,
    fragment_entry: []const u8,
    vertex_buffers: []const VertexBufferLayout,
) RenderPipeline {
    return bind.Handle.fromInt(zunk_gpu_create_render_pipeline(
        layout.toInt(),
        shader.toInt(),
        vertex_entry.ptr,
        @intCast(vertex_entry.len),
        fragment_entry.ptr,
        @intCast(fragment_entry.len),
        @ptrCast(vertex_buffers.ptr),
        @intCast(vertex_buffers.len),
    ));
}

pub fn createRenderPipelineHDR(
    layout: PipelineLayout,
    shader: ShaderModule,
    vertex_entry: []const u8,
    fragment_entry: []const u8,
    format: TextureFormat,
    blending: bool,
    vertex_buffers: []const VertexBufferLayout,
) RenderPipeline {
    return bind.Handle.fromInt(zunk_gpu_create_render_pipeline_hdr(
        layout.toInt(),
        shader.toInt(),
        vertex_entry.ptr,
        @intCast(vertex_entry.len),
        fragment_entry.ptr,
        @intCast(fragment_entry.len),
        @intFromEnum(format),
        @intFromBool(blending),
        @ptrCast(vertex_buffers.ptr),
        @intCast(vertex_buffers.len),
    ));
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

pub fn beginRenderPass(r: f32, g: f32, b: f32, a: f32) RenderPassEncoder {
    return bind.Handle.fromInt(zunk_gpu_begin_render_pass(r, g, b, a));
}

pub fn beginRenderPassHDR(view: TextureView, r: f32, g: f32, b: f32, a: f32) RenderPassEncoder {
    return bind.Handle.fromInt(zunk_gpu_begin_render_pass_hdr(view.toInt(), r, g, b, a));
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

pub fn renderPassDraw(pass: RenderPassEncoder, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
    zunk_gpu_render_pass_draw(pass.toInt(), vertex_count, instance_count, first_vertex, first_instance);
}

pub fn renderPassEnd(pass: RenderPassEncoder) void {
    zunk_gpu_render_pass_end(pass.toInt());
}

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
/// `font` is a CSS font string, e.g. "14px monospace".
pub fn measureText(text: []const u8, font: []const u8) TextMetrics {
    var out: TextMetrics = .{ .width = 0, .height = 0 };
    zunk_gpu_measure_text(
        text.ptr,
        @intCast(text.len),
        font.ptr,
        @intCast(font.len),
        &out,
    );
    return out;
}

/// Rasterize `text` into a freshly allocated rgba8unorm `Texture` of the given
/// size, using the browser's canvas 2D text shaper. `color` is the foreground
/// fill (0..1 RGBA). The texture has `TEXTURE_BINDING | COPY_DST` usage and is
/// ready to bind in the same frame.
pub fn rasterizeText(
    text: []const u8,
    font: []const u8,
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
    ));
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
