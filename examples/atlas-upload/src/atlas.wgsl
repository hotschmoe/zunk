// Instanced quads sampling an r8unorm coverage atlas (glyph-atlas style).
struct Inst {
  @location(0) rect: vec4f,   // x, y, w, h in NDC (y up)
  @location(1) uv: vec4f,     // u0, v0, u1, v1
  @location(2) color: vec4f,
}

struct Out {
  @builtin(position) pos: vec4f,
  @location(0) uv: vec2f,
  @location(1) color: vec4f,
}

@group(0) @binding(0) var atlas: texture_2d<f32>;
@group(0) @binding(1) var samp: sampler;

@vertex fn vs(@builtin(vertex_index) vi: u32, i: Inst) -> Out {
  var c = array<vec2f, 6>(
    vec2f(0, 0), vec2f(1, 0), vec2f(0, 1),
    vec2f(1, 0), vec2f(1, 1), vec2f(0, 1),
  );
  let p = c[vi];
  var o: Out;
  o.pos = vec4f(i.rect.xy + p * i.rect.zw, 0, 1);
  o.uv = vec2f(mix(i.uv.x, i.uv.z, p.x), mix(i.uv.w, i.uv.y, p.y));
  o.color = i.color;
  return o;
}

@fragment fn fs(i: Out) -> @location(0) vec4f {
  let cov = textureSample(atlas, samp, i.uv).r;
  return vec4f(i.color.rgb, i.color.a * cov);
}
