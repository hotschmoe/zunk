//! mesh-3d: a depth-tested, lit, rotating cube with feature edges and a ground
//! grid, rendered with 4x MSAA straight into the canvas, plus a second view of
//! the same cube rendered offscreen and composited as an inset. Exercises
//! zunk's 3D surface: depth attachment, index buffers, instanced draws,
//! MSAA + resolve, offscreen targets, line topology, depth bias, and
//! texture readback (the inset's pixels are logged once after frame 3).

const std = @import("std");
const zunk = @import("zunk");
const gpu = zunk.web.gpu;
const input = zunk.web.input;
const app = zunk.web.app;
const math = @import("math.zig");

const scene_src = @embedFile("scene.wgsl");
const blit_src = @embedFile("blit.wgsl");

const sample_count: u32 = 4;
const depth_format: gpu.TextureFormat = .depth32float;
const inset_size: u32 = 256;
const clear_color = [4]f32{ 0.10, 0.12, 0.16, 1.0 };

const MeshVertex = extern struct { pos: [3]f32, normal: [3]f32, color: [3]f32 };
const GridVertex = extern struct { pos: [3]f32, color: [3]f32 };
const Segment = extern struct { a: [3]f32, b: [3]f32 };

const Globals = extern struct {
    view_proj: math.Mat4,
    model: math.Mat4,
    light_dir: [4]f32,
    /// x, y: target size in pixels; z: edge width in pixels.
    screen: [4]f32,
};

// ---- geometry (built at comptime) ---------------------------------------

const half: f32 = 0.8;

const face_defs = [6]struct { n: [3]f32, u: [3]f32, v: [3]f32, color: [3]f32 }{
    .{ .n = .{ 1, 0, 0 }, .u = .{ 0, 1, 0 }, .v = .{ 0, 0, 1 }, .color = .{ 0.85, 0.35, 0.30 } },
    .{ .n = .{ -1, 0, 0 }, .u = .{ 0, 0, 1 }, .v = .{ 0, 1, 0 }, .color = .{ 0.85, 0.35, 0.30 } },
    .{ .n = .{ 0, 1, 0 }, .u = .{ 0, 0, 1 }, .v = .{ 1, 0, 0 }, .color = .{ 0.35, 0.75, 0.40 } },
    .{ .n = .{ 0, -1, 0 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 0, 1 }, .color = .{ 0.35, 0.75, 0.40 } },
    .{ .n = .{ 0, 0, 1 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 1, 0 }, .color = .{ 0.35, 0.50, 0.90 } },
    .{ .n = .{ 0, 0, -1 }, .u = .{ 0, 1, 0 }, .v = .{ 1, 0, 0 }, .color = .{ 0.35, 0.50, 0.90 } },
};

/// Four corners per face, wound counter-clockwise seen from outside
/// (u x v == n for every face above).
const cube_vertices: [24]MeshVertex = blk: {
    var out: [24]MeshVertex = undefined;
    const signs = [4][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
    for (face_defs, 0..) |f, fi| {
        for (signs, 0..) |s, ci| {
            var p: [3]f32 = undefined;
            for (0..3) |k| p[k] = half * (f.n[k] + s[0] * f.u[k] + s[1] * f.v[k]);
            out[fi * 4 + ci] = .{ .pos = p, .normal = f.n, .color = f.color };
        }
    }
    break :blk out;
};

const cube_indices: [36]u16 = blk: {
    var out: [36]u16 = undefined;
    for (0..6) |f| {
        const b: u16 = @intCast(f * 4);
        const quad = [6]u16{ 0, 1, 2, 0, 2, 3 };
        for (quad, 0..) |q, i| out[f * 6 + i] = b + q;
    }
    break :blk out;
};

/// The 12 cube edges: corner pairs that differ in exactly one coordinate.
const cube_edges: [12]Segment = blk: {
    var out: [12]Segment = undefined;
    var n: usize = 0;
    for (0..8) |i| {
        for (0..3) |axis| {
            if (i & (@as(usize, 1) << @intCast(axis)) != 0) continue;
            var a: [3]f32 = undefined;
            var b: [3]f32 = undefined;
            for (0..3) |k| {
                const sign: f32 = if (i & (@as(usize, 1) << @intCast(k)) != 0) 1 else -1;
                a[k] = sign * half;
                b[k] = if (k == axis) half else sign * half;
            }
            a[axis] = -half;
            out[n] = .{ .a = a, .b = b };
            n += 1;
        }
    }
    break :blk out;
};

const grid_half: i32 = 5;
const grid_vertices: [(2 * grid_half + 1) * 4]GridVertex = blk: {
    var out: [(2 * grid_half + 1) * 4]GridVertex = undefined;
    var n: usize = 0;
    const extent: f32 = @floatFromInt(grid_half);
    var i: i32 = -grid_half;
    while (i <= grid_half) : (i += 1) {
        const t: f32 = @floatFromInt(i);
        const shade: f32 = if (i == 0) 0.75 else 0.40;
        const c = [3]f32{ shade, shade, shade + 0.05 };
        out[n + 0] = .{ .pos = .{ t, -1, -extent }, .color = c };
        out[n + 1] = .{ .pos = .{ t, -1, extent }, .color = c };
        out[n + 2] = .{ .pos = .{ -extent, -1, t }, .color = c };
        out[n + 3] = .{ .pos = .{ extent, -1, t }, .color = c };
        n += 4;
    }
    break :blk out;
};

// ---- GPU state ------------------------------------------------------------

/// Everything that depends on a render target's size: MSAA colour + depth.
const Target = struct {
    width: u32 = 0,
    height: u32 = 0,
    msaa_color: gpu.Texture = .null_handle,
    msaa_view: gpu.TextureView = .null_handle,
    depth: gpu.Texture = .null_handle,
    depth_view: gpu.TextureView = .null_handle,

    fn resize(self: *Target, w: u32, h: u32) void {
        if (w == self.width and h == self.height) return;
        self.destroy();
        self.width = w;
        self.height = h;
        self.msaa_color = gpu.createTextureMultisampled(w, h, gpu.canvasFormat(), gpu.TextureUsage.RENDER_ATTACHMENT, sample_count);
        self.msaa_view = gpu.createTextureView(self.msaa_color);
        self.depth = gpu.createDepthTexture(w, h, depth_format, sample_count);
        self.depth_view = gpu.createTextureView(self.depth);
    }

    fn destroy(self: *Target) void {
        if (self.width == 0) return;
        gpu.release(self.msaa_view);
        gpu.release(self.depth_view);
        gpu.destroyTexture(self.msaa_color);
        gpu.destroyTexture(self.depth);
    }
};

var mesh_pipeline: gpu.RenderPipeline = undefined;
var grid_pipeline: gpu.RenderPipeline = undefined;
var edge_pipeline: gpu.RenderPipeline = undefined;
var blit_pipeline: gpu.RenderPipeline = undefined;

var vertex_buf: gpu.Buffer = undefined;
var index_buf: gpu.Buffer = undefined;
var grid_buf: gpu.Buffer = undefined;
var edge_buf: gpu.Buffer = undefined;

var main_uniform: gpu.Buffer = undefined;
var main_group: gpu.BindGroup = undefined;
var inset_uniform: gpu.Buffer = undefined;
var inset_group: gpu.BindGroup = undefined;

var main_target: Target = .{};
var inset_target: Target = .{};
var inset_texture: gpu.Texture = undefined;
var inset_view: gpu.TextureView = undefined;
var blit_group: gpu.BindGroup = undefined;

var css_w: u32 = 0;
var css_h: u32 = 0;
var time: f32 = 0;
var frame_count: u32 = 0;

var readback: gpu.Readback = undefined;
var readback_state: enum { idle, requested, done } = .idle;
var readback_data: [inset_size * inset_size * 4]u8 = undefined;

export fn init() void {
    input.init();
    app.setTitle("zunk mesh-3d");

    const fmt = gpu.canvasFormat();
    const scene = gpu.createShaderModule(scene_src);

    const ubo_vis = gpu.ShaderVisibility.VERTEX | gpu.ShaderVisibility.FRAGMENT;
    const scene_bgl = gpu.createBindGroupLayout(&.{
        gpu.BindGroupLayoutEntry.initBuffer(0, ubo_vis, .uniform).withMinSize(@sizeOf(Globals)),
    });
    const scene_layout = gpu.createPipelineLayout(&.{scene_bgl});

    const mesh_attrs = [_]gpu.VertexAttribute{
        .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
        .{ .format = .float32x3, .offset = 12, .shader_location = 1 },
        .{ .format = .float32x3, .offset = 24, .shader_location = 2 },
    };
    const grid_attrs = [_]gpu.VertexAttribute{
        .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
        .{ .format = .float32x3, .offset = 12, .shader_location = 1 },
    };
    // Per-instance attributes: one Segment per edge quad.
    const edge_attrs = [_]gpu.VertexAttribute{
        .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
        .{ .format = .float32x3, .offset = 12, .shader_location = 1 },
    };
    const mesh_layouts = [_]gpu.VertexBufferLayout{gpu.VertexBufferLayout.fromSlice(@sizeOf(MeshVertex), .vertex, &mesh_attrs)};
    const grid_layouts = [_]gpu.VertexBufferLayout{gpu.VertexBufferLayout.fromSlice(@sizeOf(GridVertex), .vertex, &grid_attrs)};
    const edge_layouts = [_]gpu.VertexBufferLayout{gpu.VertexBufferLayout.fromSlice(@sizeOf(Segment), .instance, &edge_attrs)};

    mesh_pipeline = gpu.createRenderPipelineDesc(.{
        .layout = scene_layout,
        .shader = scene,
        .vertex_entry = "vs_mesh",
        .fragment_entry = "fs_mesh",
        .vertex_buffers = &mesh_layouts,
        .color_format = fmt,
        .blend = .none,
        .cull_mode = .back,
        .depth = .{ .format = depth_format },
        .sample_count = sample_count,
    });
    grid_pipeline = gpu.createRenderPipelineDesc(.{
        .layout = scene_layout,
        .shader = scene,
        .vertex_entry = "vs_grid",
        .fragment_entry = "fs_flat",
        .vertex_buffers = &grid_layouts,
        .color_format = fmt,
        .blend = .none,
        .topology = .line_list,
        .depth = .{ .format = depth_format },
        .sample_count = sample_count,
    });
    edge_pipeline = gpu.createRenderPipelineDesc(.{
        .layout = scene_layout,
        .shader = scene,
        .vertex_entry = "vs_edge",
        .fragment_entry = "fs_flat",
        .vertex_buffers = &edge_layouts,
        .color_format = fmt,
        .blend = .none,
        .depth = .{ .format = depth_format, .write_enabled = false, .compare = .less_equal },
        .sample_count = sample_count,
    });

    const blit = gpu.createShaderModule(blit_src);
    const blit_bgl = gpu.createBindGroupLayout(&.{
        gpu.BindGroupLayoutEntry.initTexture(0, gpu.ShaderVisibility.FRAGMENT, .float),
        gpu.BindGroupLayoutEntry.initSampler(1, gpu.ShaderVisibility.FRAGMENT, .filtering),
    });
    blit_pipeline = gpu.createRenderPipelineDesc(.{
        .layout = gpu.createPipelineLayout(&.{blit_bgl}),
        .shader = blit,
        .vertex_entry = "vs_blit",
        .fragment_entry = "fs_blit",
        .color_format = fmt,
        .blend = .none,
        // The main pass has a depth buffer, so every pipeline in it needs a
        // matching (here: disabled) depth state.
        .depth = .{ .format = depth_format, .write_enabled = false, .compare = .always },
        .sample_count = sample_count,
    });

    vertex_buf = createWith(gpu.BufferUsage.VERTEX, MeshVertex, &cube_vertices);
    index_buf = createWith(gpu.BufferUsage.INDEX, u16, &cube_indices);
    grid_buf = createWith(gpu.BufferUsage.VERTEX, GridVertex, &grid_vertices);
    edge_buf = createWith(gpu.BufferUsage.VERTEX, Segment, &cube_edges);

    main_uniform = gpu.createUniformBuffer(@sizeOf(Globals));
    main_group = gpu.createBindGroup(scene_bgl, &.{gpu.BindGroupEntry.initBufferFull(0, main_uniform, @sizeOf(Globals))});
    inset_uniform = gpu.createUniformBuffer(@sizeOf(Globals));
    inset_group = gpu.createBindGroup(scene_bgl, &.{gpu.BindGroupEntry.initBufferFull(0, inset_uniform, @sizeOf(Globals))});

    inset_texture = gpu.createRenderTarget(inset_size, inset_size, fmt);
    inset_view = gpu.createTextureView(inset_texture);
    inset_target.resize(inset_size, inset_size);
    blit_group = gpu.createBindGroup(blit_bgl, &.{
        gpu.BindGroupEntry.initTextureView(0, inset_view),
        gpu.BindGroupEntry.initSampler(1, gpu.createSampler(.{ .mag_filter = .linear, .min_filter = .linear })),
    });

    readback = gpu.Readback.init(inset_size, inset_size, 4);
}

fn createWith(usage: u32, comptime T: type, items: []const T) gpu.Buffer {
    const buf = gpu.createBuffer(@intCast(items.len * @sizeOf(T)), usage | gpu.BufferUsage.COPY_DST);
    gpu.bufferWriteTyped(T, buf, 0, items);
    return buf;
}

export fn resize(w: u32, h: u32) void {
    css_w = w;
    css_h = h;
}

fn globals(model: math.Mat4, eye: math.Vec3, w: f32, h: f32, edge_px: f32) Globals {
    const proj = math.perspective(0.9, w / h, 0.1, 50.0);
    const view = math.lookAt(eye, .{ 0, -0.2, 0 }, .{ 0, 1, 0 });
    return .{
        .view_proj = math.mul(proj, view),
        .model = model,
        .light_dir = .{ -0.5, -1.0, -0.4, 0 },
        .screen = .{ w, h, edge_px, 0 },
    };
}

/// Grid, then cube, then edges: opaque geometry first, then the quads that
/// depend on its depth.
fn drawScene(pass: gpu.RenderPassEncoder, group: gpu.BindGroup) void {
    gpu.renderPassSetBindGroup(pass, 0, group);

    gpu.renderPassSetPipeline(pass, grid_pipeline);
    gpu.renderPassSetVertexBuffer(pass, 0, grid_buf, 0, @sizeOf(@TypeOf(grid_vertices)));
    gpu.renderPassDraw(pass, grid_vertices.len, 1, 0, 0);

    gpu.renderPassSetPipeline(pass, mesh_pipeline);
    gpu.renderPassSetVertexBuffer(pass, 0, vertex_buf, 0, @sizeOf(@TypeOf(cube_vertices)));
    gpu.renderPassSetIndexBuffer(pass, index_buf, .uint16, 0, @sizeOf(@TypeOf(cube_indices)));
    gpu.renderPassDrawIndexed(pass, cube_indices.len, 1, 0, 0, 0);

    gpu.renderPassSetPipeline(pass, edge_pipeline);
    gpu.renderPassSetVertexBuffer(pass, 0, edge_buf, 0, @sizeOf(@TypeOf(cube_edges)));
    gpu.renderPassDraw(pass, 6, cube_edges.len, 0, 0); // 6 verts x 12 instances
}

export fn frame(dt: f32) void {
    input.poll();
    if (css_w == 0 or css_h == 0) return;
    time += dt;
    frame_count += 1;

    const dpr = input.getDevicePixelRatio();
    const px_w: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(css_w)) * dpr));
    const px_h: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(css_h)) * dpr));
    main_target.resize(px_w, px_h);

    const model = math.mul(math.rotateY(time * 0.8), math.rotateX(0.35));
    const orbit = time * 0.3;
    const main_g = globals(model, .{ 4.5 * @sin(orbit), 2.6, 4.5 * @cos(orbit) }, @floatFromInt(px_w), @floatFromInt(px_h), 3.0 * dpr);
    gpu.bufferWriteTyped(Globals, main_uniform, 0, &.{main_g});
    const inset_g = globals(model, .{ 0, 4.0, 3.0 }, inset_size, inset_size, 2.0);
    gpu.bufferWriteTyped(Globals, inset_uniform, 0, &.{inset_g});

    // 1. Inset: MSAA colour + depth, resolved into `inset_view`.
    const ipass = gpu.beginRenderPassDesc(.{
        .color = inset_target.msaa_view,
        .resolve = inset_view,
        .color_store = .discard,
        .clear = .{ 0.16, 0.12, 0.10, 1 },
        .depth = inset_target.depth_view,
        .depth_store = .discard,
    });
    drawScene(ipass, inset_group);
    gpu.renderPassEnd(ipass);

    // 2. Main scene: MSAA colour + depth, resolved into the canvas.
    const pass = gpu.beginRenderPassDesc(.{
        .color = main_target.msaa_view,
        .resolve = gpu.canvasView(),
        .color_store = .discard,
        .clear = clear_color,
        .depth = main_target.depth_view,
        .depth_store = .discard,
    });
    drawScene(pass, main_group);

    // 3. Composite the inset in the bottom-right corner.
    const iw: f32 = 256 * dpr;
    const margin: f32 = 16 * dpr;
    gpu.renderPassSetViewport(pass, @as(f32, @floatFromInt(px_w)) - iw - margin, @as(f32, @floatFromInt(px_h)) - iw - margin, iw, iw, 0, 1);
    gpu.renderPassSetPipeline(pass, blit_pipeline);
    gpu.renderPassSetBindGroup(pass, 0, blit_group);
    gpu.renderPassDraw(pass, 6, 1, 0, 0);
    gpu.renderPassEnd(pass);

    if (frame_count == 3 and readback_state == .idle) readback.encode(gpu.frameEncoder(), inset_texture);
    gpu.present();
    if (frame_count == 3 and readback_state == .idle) {
        readback.request();
        readback_state = .requested;
    }
    pollReadback();
}

fn pollReadback() void {
    if (readback_state != .requested) return;
    switch (readback.poll()) {
        .pending, .idle => {},
        .failed => {
            app.logWarn("readback failed");
            readback.deinit();
            readback_state = .done;
        },
        .mapped => {
            readback.read(&readback_data);
            const corner = readback.pixel(&readback_data, 2, 2);
            const center = readback.pixel(&readback_data, inset_size / 2, inset_size / 2);
            var buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "readback corner={any} center={any}", .{ corner, center }) catch "readback ok";
            app.logInfo(msg);
            readback.deinit();
            readback_state = .done;
        },
    }
}
