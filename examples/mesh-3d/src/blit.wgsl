// Draws a texture over the current viewport (two triangles from the vertex id).
@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var samp: sampler;

struct Out {
  @builtin(position) pos: vec4f,
  @location(0) uv: vec2f,
}

@vertex fn vs_blit(@builtin(vertex_index) vi: u32) -> Out {
  var corner = array<vec2f, 6>(
    vec2f(0, 0), vec2f(1, 0), vec2f(0, 1),
    vec2f(1, 0), vec2f(1, 1), vec2f(0, 1),
  );
  let c = corner[vi];
  var o: Out;
  o.pos = vec4f(c.x * 2.0 - 1.0, 1.0 - c.y * 2.0, 0.0, 1.0);
  o.uv = c;
  return o;
}

@fragment fn fs_blit(i: Out) -> @location(0) vec4f {
  return textureSample(tex, samp, i.uv);
}

// Solid highlight colour; the pipeline's stencil test restricts where it lands.
@fragment fn fs_tint(i: Out) -> @location(0) vec4f {
  return vec4f(1.0, 0.85, 0.1, 0.45);
}
