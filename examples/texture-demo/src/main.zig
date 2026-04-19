// Sampler + texture acceptance demo (workstream 1, see
// docs/from_teak_team/zunk-roadmap.md). Uploads a 2x2 rgba8 texture with four
// colored pixels, binds it with a linear sampler, and renders a fullscreen
// quad sampling the texture. A linear filter should interpolate the four
// pixels across the canvas.

const zunk = @import("zunk");
const gpu = zunk.web.gpu;
const input = zunk.web.input;
const app = zunk.web.app;

const texels = [_]u8{
    0xff, 0x00, 0x00, 0xff, // (0,0) red
    0x00, 0xff, 0x00, 0xff, // (1,0) green
    0x00, 0x00, 0xff, 0xff, // (0,1) blue
    0xff, 0xff, 0x00, 0xff, // (1,1) yellow
};

const shader_src =
    \\struct VSOut {
    \\  @builtin(position) pos: vec4f,
    \\  @location(0) uv: vec2f,
    \\};
    \\
    \\@vertex fn vertexMain(@builtin(vertex_index) vid: u32) -> VSOut {
    \\  // Two-triangle fullscreen quad, generated from vertex_index.
    \\  var p = array<vec2f, 6>(
    \\    vec2f(-1.0, -1.0), vec2f( 1.0, -1.0), vec2f(-1.0,  1.0),
    \\    vec2f( 1.0, -1.0), vec2f( 1.0,  1.0), vec2f(-1.0,  1.0),
    \\  );
    \\  var uv = array<vec2f, 6>(
    \\    vec2f(0.0, 1.0), vec2f(1.0, 1.0), vec2f(0.0, 0.0),
    \\    vec2f(1.0, 1.0), vec2f(1.0, 0.0), vec2f(0.0, 0.0),
    \\  );
    \\  var o: VSOut;
    \\  o.pos = vec4f(p[vid], 0.0, 1.0);
    \\  o.uv = uv[vid];
    \\  return o;
    \\}
    \\
    \\@group(0) @binding(0) var tex: texture_2d<f32>;
    \\@group(0) @binding(1) var samp: sampler;
    \\
    \\@fragment fn fragmentMain(in: VSOut) -> @location(0) vec4f {
    \\  return textureSample(tex, samp, in.uv);
    \\}
;

var pipeline: gpu.RenderPipeline = undefined;
var bind_group: gpu.BindGroup = undefined;

export fn init() void {
    input.init();
    app.setTitle("zunk texture-demo");

    const texture = gpu.createTexture(
        2,
        2,
        .rgba8unorm,
        gpu.TextureUsage.TEXTURE_BINDING | gpu.TextureUsage.COPY_DST,
    );
    gpu.writeTexture(texture, &texels, 2 * 4, 2, 2);
    const view = gpu.createTextureView(texture);

    const sampler = gpu.createSampler(.{
        .mag_filter = .linear,
        .min_filter = .linear,
    });

    const bgl = gpu.createBindGroupLayout(&.{
        gpu.BindGroupLayoutEntry.initTexture(0, gpu.ShaderVisibility.FRAGMENT, .float),
        gpu.BindGroupLayoutEntry.initSampler(1, gpu.ShaderVisibility.FRAGMENT, .filtering),
    });
    bind_group = gpu.createBindGroup(bgl, &.{
        gpu.BindGroupEntry.initTextureView(0, view),
        gpu.BindGroupEntry.initSampler(1, sampler),
    });

    const shader = gpu.createShaderModule(shader_src);
    const pl = gpu.createPipelineLayout(&.{bgl});
    pipeline = gpu.createRenderPipeline(pl, shader, "vertexMain", "fragmentMain", &.{});
}

export fn frame(_: f32) void {
    input.poll();

    const pass = gpu.beginRenderPass(0.0, 0.0, 0.0, 1.0);
    gpu.renderPassSetPipeline(pass, pipeline);
    gpu.renderPassSetBindGroup(pass, 0, bind_group);
    gpu.renderPassDraw(pass, 6, 1, 0, 0);
    gpu.renderPassEnd(pass);
    gpu.present();
}

export fn resize(_: u32, _: u32) void {}
