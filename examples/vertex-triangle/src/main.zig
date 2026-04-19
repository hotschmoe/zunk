// Vertex-buffer acceptance demo: exercises createRenderPipeline's vertex_buffers
// param and renderPassSetVertexBuffer by drawing a triangle from interleaved
// {pos: vec2, color: vec3} vertices uploaded to a VERTEX|COPY_DST buffer.

const zunk = @import("zunk");
const gpu = zunk.web.gpu;
const input = zunk.web.input;
const app = zunk.web.app;

const Vertex = extern struct {
    pos: [2]f32,
    color: [3]f32,
};

const vertices = [_]Vertex{
    .{ .pos = .{ 0.0, 0.6 }, .color = .{ 1.0, 0.2, 0.2 } },
    .{ .pos = .{ -0.6, -0.6 }, .color = .{ 0.2, 1.0, 0.2 } },
    .{ .pos = .{ 0.6, -0.6 }, .color = .{ 0.2, 0.2, 1.0 } },
};
const vertex_bytes = @sizeOf(@TypeOf(vertices));

const shader_src =
    \\struct VSOut {
    \\  @builtin(position) pos: vec4f,
    \\  @location(0) color: vec3f,
    \\};
    \\
    \\@vertex fn vertexMain(
    \\  @location(0) in_pos: vec2f,
    \\  @location(1) in_color: vec3f,
    \\) -> VSOut {
    \\  var o: VSOut;
    \\  o.pos = vec4f(in_pos, 0.0, 1.0);
    \\  o.color = in_color;
    \\  return o;
    \\}
    \\
    \\@fragment fn fragmentMain(in: VSOut) -> @location(0) vec4f {
    \\  return vec4f(in.color, 1.0);
    \\}
;

var vertex_buffer: gpu.Buffer = undefined;
var pipeline: gpu.RenderPipeline = undefined;

export fn init() void {
    input.init();
    app.setTitle("zunk vertex-triangle");

    const shader = gpu.createShaderModule(shader_src);
    const pl = gpu.createPipelineLayout(&.{});

    const attrs = [_]gpu.VertexAttribute{
        .{ .shader_location = 0, .format = .float32x2, .offset = 0 },
        .{ .shader_location = 1, .format = .float32x3, .offset = 8 },
    };
    const layouts = [_]gpu.VertexBufferLayout{
        gpu.VertexBufferLayout.fromSlice(@sizeOf(Vertex), .vertex, &attrs),
    };

    pipeline = gpu.createRenderPipeline(pl, shader, "vertexMain", "fragmentMain", &layouts);

    vertex_buffer = gpu.createBuffer(vertex_bytes, gpu.BufferUsage.VERTEX | gpu.BufferUsage.COPY_DST);
    gpu.bufferWriteTyped(Vertex, vertex_buffer, 0, &vertices);
}

export fn frame(_: f32) void {
    input.poll();

    const pass = gpu.beginRenderPass(0.05, 0.07, 0.09, 1.0);
    gpu.renderPassSetPipeline(pass, pipeline);
    gpu.renderPassSetVertexBuffer(pass, 0, vertex_buffer, 0, vertex_bytes);
    gpu.renderPassDraw(pass, 3, 1, 0, 0);
    gpu.renderPassEnd(pass);
    gpu.present();
}

export fn resize(_: u32, _: u32) void {}
