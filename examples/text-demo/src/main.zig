// Text-to-texture acceptance demo (workstream 2, see
// docs/from_teak_team/zunk-roadmap.md). Measures "Hello, world!" with the
// browser's text shaper, rasterizes it into a GPU texture, then samples the
// texture over a pixel-sized quad centered on the canvas. Resizing the window
// updates the uniform buffer so the text stays pixel-accurate.

const zunk = @import("zunk");
const gpu = zunk.web.gpu;
const input = zunk.web.input;
const app = zunk.web.app;

const label_text = "Hello, world!";
const label_font = "32px sans-serif";

const shader_src =
    \\struct Uniforms {
    \\  // Clip-space rectangle: (x0, y0, x1, y1).
    \\  rect: vec4f,
    \\};
    \\@group(0) @binding(0) var<uniform> u: Uniforms;
    \\@group(0) @binding(1) var tex: texture_2d<f32>;
    \\@group(0) @binding(2) var samp: sampler;
    \\
    \\struct VSOut {
    \\  @builtin(position) pos: vec4f,
    \\  @location(0) uv: vec2f,
    \\};
    \\
    \\@vertex fn vertexMain(@builtin(vertex_index) vid: u32) -> VSOut {
    \\  // Two-triangle quad in (rect.xy)..(rect.zw) with top-left UV origin.
    \\  let corners = array<vec2f, 6>(
    \\    vec2f(0.0, 0.0), vec2f(1.0, 0.0), vec2f(0.0, 1.0),
    \\    vec2f(1.0, 0.0), vec2f(1.0, 1.0), vec2f(0.0, 1.0),
    \\  );
    \\  let c = corners[vid];
    \\  var o: VSOut;
    \\  let x = mix(u.rect.x, u.rect.z, c.x);
    \\  let y = mix(u.rect.w, u.rect.y, c.y); // flip so c.y=0 is top
    \\  o.pos = vec4f(x, y, 0.0, 1.0);
    \\  o.uv = c;
    \\  return o;
    \\}
    \\
    \\@fragment fn fragmentMain(in: VSOut) -> @location(0) vec4f {
    \\  return textureSample(tex, samp, in.uv);
    \\}
;

var pipeline: gpu.RenderPipeline = undefined;
var bind_group: gpu.BindGroup = undefined;
var uniform_buffer: gpu.Buffer = undefined;
var text_w: u32 = 0;
var text_h: u32 = 0;

export fn init() void {
    input.init();
    app.setTitle("zunk text-demo");

    const metrics = gpu.measureText(label_text, label_font);
    text_w = metrics.width;
    text_h = metrics.height;

    const tex = gpu.rasterizeText(label_text, label_font, .{ 1.0, 1.0, 1.0, 1.0 }, text_w, text_h);
    const view = gpu.createTextureView(tex);

    const sampler = gpu.createSampler(gpu.SamplerDescriptor.init(
        .linear,
        .linear,
        .clamp_to_edge,
        .clamp_to_edge,
    ));

    uniform_buffer = gpu.createUniformBuffer(16);
    // Default rect covers the full clip space until resize() fires.
    const default_rect = [4]f32{ -1.0, -1.0, 1.0, 1.0 };
    gpu.bufferWriteTyped(f32, uniform_buffer, 0, &default_rect);

    const bgl = gpu.createBindGroupLayout(&.{
        gpu.BindGroupLayoutEntry.initBuffer(0, gpu.ShaderVisibility.VERTEX, .uniform),
        gpu.BindGroupLayoutEntry.initTexture(1, gpu.ShaderVisibility.FRAGMENT, .float),
        gpu.BindGroupLayoutEntry.initSampler(2, gpu.ShaderVisibility.FRAGMENT, .filtering),
    });
    bind_group = gpu.createBindGroup(bgl, &.{
        gpu.BindGroupEntry.initBufferFull(0, uniform_buffer, 16),
        gpu.BindGroupEntry.initTextureView(1, view),
        gpu.BindGroupEntry.initSampler(2, sampler),
    });

    const shader = gpu.createShaderModule(shader_src);
    const pl = gpu.createPipelineLayout(&.{bgl});
    pipeline = gpu.createRenderPipeline(pl, shader, "vertexMain", "fragmentMain", &.{});
}

export fn frame(_: f32) void {
    input.poll();

    const pass = gpu.beginRenderPass(0.08, 0.08, 0.10, 1.0);
    gpu.renderPassSetPipeline(pass, pipeline);
    gpu.renderPassSetBindGroup(pass, 0, bind_group);
    gpu.renderPassDraw(pass, 6, 1, 0, 0);
    gpu.renderPassEnd(pass);
    gpu.present();
}

export fn resize(w: u32, h: u32) void {
    if (w == 0 or h == 0 or text_w == 0 or text_h == 0) return;

    // Place the text at pixel-accurate size, centered on the canvas.
    const canvas_w: f32 = @floatFromInt(w);
    const canvas_h: f32 = @floatFromInt(h);
    const tw: f32 = @floatFromInt(text_w);
    const th: f32 = @floatFromInt(text_h);

    const half_w = tw / canvas_w;
    const half_h = th / canvas_h;
    const rect = [4]f32{ -half_w, -half_h, half_w, half_h };
    gpu.bufferWriteTyped(f32, uniform_buffer, 0, &rect);
}
