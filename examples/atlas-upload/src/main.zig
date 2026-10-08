//! atlas-upload: glyph-atlas primitives. Packs three bitmaps into one
//! `r8unorm` texture with `gpu.writeTextureRegion` (a procedural ring, a
//! gradient uploaded from a padded source stride, and a CJK glyph rasterized
//! by `gpu.rasterCluster`), then draws instanced quads that sample sub-rects
//! of it, as a text renderer would.

const std = @import("std");
const zunk = @import("zunk");
const gpu = zunk.web.gpu;
const app = zunk.web.app;
const input = zunk.web.input;

const shader_src = @embedFile("atlas.wgsl");

const atlas_w: u32 = 128;
const atlas_h: u32 = 80;
const clear_color = [4]f32{ 0.09, 0.10, 0.13, 1.0 };

const Instance = extern struct { rect: [4]f32, uv: [4]f32, color: [4]f32 };

var pipeline: gpu.RenderPipeline = undefined;
var group: gpu.BindGroup = undefined;
var instance_buf: gpu.Buffer = undefined;
var instance_count: u32 = 0;
var css_w: u32 = 0;
var css_h: u32 = 0;
var logged = false;

/// Atlas sub-rect -> uv rect.
fn uvOf(x: u32, y: u32, w: u32, h: u32) [4]f32 {
    const aw: f32 = @floatFromInt(atlas_w);
    const ah: f32 = @floatFromInt(atlas_h);
    return .{ @as(f32, @floatFromInt(x)) / aw, @as(f32, @floatFromInt(y)) / ah, @as(f32, @floatFromInt(x + w)) / aw, @as(f32, @floatFromInt(y + h)) / ah };
}

export fn init() void {
    input.init();
    app.setTitle("zunk atlas-upload");

    const atlas = gpu.createTexture(atlas_w, atlas_h, .r8unorm, gpu.TextureUsage.TEXTURE_BINDING | gpu.TextureUsage.COPY_DST);

    // Zero the whole atlas first (R8 rows must be uploaded with any stride).
    var zeros: [atlas_w * atlas_h]u8 = @splat(0);
    gpu.writeTexture(atlas, &zeros, atlas_w, atlas_w, atlas_h);

    // Sub-rect 1 (0,0 48x48): a ring, tightly packed.
    var ring: [48 * 48]u8 = undefined;
    for (0..48) |yy| for (0..48) |xx| {
        const dx = @as(f32, @floatFromInt(xx)) - 23.5;
        const dy = @as(f32, @floatFromInt(yy)) - 23.5;
        const r = @sqrt(dx * dx + dy * dy);
        const v = 1.0 - @min(1.0, @abs(r - 17.0) / 4.0);
        ring[yy * 48 + xx] = @intFromFloat(@max(0.0, v) * 255.0);
    };
    gpu.writeTextureRegion(atlas, 0, 0, 48, 48, &ring, 48);

    // Sub-rect 2 (56,0 40x24): horizontal gradient from a source whose rows
    // are padded to 64 bytes, proving `bytes_per_row` != width works.
    var grad: [64 * 24]u8 = @splat(0xEE); // padding bytes must not leak into the atlas
    for (0..24) |yy| for (0..40) |xx| {
        grad[yy * 64 + xx] = @intCast(xx * 255 / 39);
    };
    gpu.writeTextureRegion(atlas, 56, 0, 40, 24, &grad, 64);

    // Sub-rect 3 (0,52+ ...): a CJK cluster from canvas2D, placed at (56, 28).
    var cluster_pixels: [64 * 64]u8 = undefined;
    const bmp = gpu.rasterCluster("漢", "500 40px sans-serif", 40, &cluster_pixels);
    const cw = bmp.metrics.width;
    const ch = bmp.metrics.height;
    if (bmp.pixels.len == cw * ch and cw > 0 and cw <= atlas_w - 56 and ch <= atlas_h - 28) {
        gpu.writeTextureRegion(atlas, 56, 28, cw, ch, bmp.pixels, cw);
    }
    {
        var buf: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "cluster {}x{} bearing=({}, {}) advance={d:.1} truncated={}", .{ cw, ch, bmp.metrics.bearing_x, bmp.metrics.bearing_y, bmp.metrics.advance, bmp.truncated }) catch "cluster";
        app.logInfo(msg);
    }

    const shader = gpu.createShaderModule(shader_src);
    const bgl = gpu.createBindGroupLayout(&.{
        gpu.BindGroupLayoutEntry.initTexture(0, gpu.ShaderVisibility.FRAGMENT, .float),
        gpu.BindGroupLayoutEntry.initSampler(1, gpu.ShaderVisibility.FRAGMENT, .filtering),
    });
    const attrs = [_]gpu.VertexAttribute{
        .{ .format = .float32x4, .offset = 0, .shader_location = 0 },
        .{ .format = .float32x4, .offset = 16, .shader_location = 1 },
        .{ .format = .float32x4, .offset = 32, .shader_location = 2 },
    };
    const layouts = [_]gpu.VertexBufferLayout{gpu.VertexBufferLayout.fromSlice(@sizeOf(Instance), .instance, &attrs)};
    pipeline = gpu.createRenderPipelineDesc(.{
        .layout = gpu.createPipelineLayout(&.{bgl}),
        .shader = shader,
        .vertex_entry = "vs",
        .fragment_entry = "fs",
        .vertex_buffers = &layouts,
        .blend = .alpha,
    });
    group = gpu.createBindGroup(bgl, &.{
        gpu.BindGroupEntry.initTextureView(0, gpu.createTextureView(atlas)),
        gpu.BindGroupEntry.initSampler(1, gpu.createSampler(.{ .mag_filter = .linear, .min_filter = .linear })),
    });

    // Instances: the same sub-rects drawn several times, different tints/sizes.
    const ring_uv = uvOf(0, 0, 48, 48);
    const grad_uv = uvOf(56, 0, 40, 24);
    const han_uv = uvOf(56, 28, cw, ch);
    const han_aspect: f32 = if (ch > 0) @as(f32, @floatFromInt(cw)) / @as(f32, @floatFromInt(ch)) else 1;
    const items = [_]Instance{
        .{ .rect = .{ -0.85, 0.15, 0.5, 0.7 }, .uv = ring_uv, .color = .{ 0.95, 0.55, 0.25, 1 } },
        .{ .rect = .{ -0.30, 0.45, 0.30, 0.4 }, .uv = ring_uv, .color = .{ 0.35, 0.80, 0.95, 1 } },
        .{ .rect = .{ 0.10, 0.45, 0.80, 0.40 }, .uv = grad_uv, .color = .{ 0.55, 0.90, 0.45, 1 } },
        .{ .rect = .{ -0.85, -0.85, 0.5 * han_aspect, 0.5 }, .uv = han_uv, .color = .{ 0.95, 0.95, 0.95, 1 } },
        .{ .rect = .{ -0.15, -0.85, 0.7 * han_aspect, 0.7 }, .uv = han_uv, .color = .{ 0.95, 0.40, 0.55, 1 } },
        .{ .rect = .{ 0.55, -0.60, 0.4, 0.4 }, .uv = ring_uv, .color = .{ 0.85, 0.80, 0.30, 0.7 } },
    };
    instance_count = items.len;
    instance_buf = gpu.createBuffer(@sizeOf(@TypeOf(items)), gpu.BufferUsage.VERTEX | gpu.BufferUsage.COPY_DST);
    gpu.bufferWriteTyped(Instance, instance_buf, 0, &items);
}

export fn resize(w: u32, h: u32) void {
    css_w = w;
    css_h = h;
}

export fn frame(dt: f32) void {
    _ = dt;
    input.poll();
    if (css_w == 0 or css_h == 0) return;
    const pass = gpu.beginRenderPassDesc(.{ .clear = clear_color });
    gpu.renderPassSetPipeline(pass, pipeline);
    gpu.renderPassSetBindGroup(pass, 0, group);
    gpu.renderPassSetVertexBuffer(pass, 0, instance_buf, 0, instance_count * @sizeOf(Instance));
    gpu.renderPassDraw(pass, 6, instance_count, 0, 0);
    gpu.renderPassEnd(pass);
    gpu.present();
    if (!logged) {
        logged = true;
        app.logInfo("atlas-upload: drew instanced quads from sub-rect uploads");
    }
}
