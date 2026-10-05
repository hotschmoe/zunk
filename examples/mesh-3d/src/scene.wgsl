// One uniform block shared by every pipeline of the scene.
struct Globals {
  view_proj: mat4x4f,
  model: mat4x4f,
  light_dir: vec4f,   // xyz = direction the light travels
  screen: vec4f,      // x,y = target size in px, z = edge width in px
}
@group(0) @binding(0) var<uniform> g: Globals;

// ---- lit, flat-coloured triangles -------------------------------------
struct MeshOut {
  @builtin(position) pos: vec4f,
  @location(0) normal: vec3f,
  @location(1) color: vec3f,
}

@vertex fn vs_mesh(
  @location(0) p: vec3f,
  @location(1) n: vec3f,
  @location(2) c: vec3f,
) -> MeshOut {
  var o: MeshOut;
  o.pos = g.view_proj * g.model * vec4f(p, 1.0);
  o.normal = (g.model * vec4f(n, 0.0)).xyz;
  o.color = c;
  return o;
}

@fragment fn fs_mesh(i: MeshOut) -> @location(0) vec4f {
  let l = max(dot(normalize(i.normal), -normalize(g.light_dir.xyz)), 0.0);
  return vec4f(i.color * (0.25 + 0.75 * l), 1.0);
}

// ---- hardware line-list (ground grid) ----------------------------------
struct FlatOut {
  @builtin(position) pos: vec4f,
  @location(0) color: vec3f,
}

@vertex fn vs_grid(@location(0) p: vec3f, @location(1) c: vec3f) -> FlatOut {
  var o: FlatOut;
  o.pos = g.view_proj * vec4f(p, 1.0);
  o.color = c;
  return o;
}

@fragment fn fs_flat(i: FlatOut) -> @location(0) vec4f {
  return vec4f(i.color, 1.0);
}

// ---- instanced camera-facing edge quads ---------------------------------
// One instance per segment (a, b in model space); six vertices per instance
// expand the segment into a quad `g.screen.z` pixels wide. Pulled towards the
// camera a hair so edges sit on the faces they outline.
@vertex fn vs_edge(
  @builtin(vertex_index) vi: u32,
  @location(0) a: vec3f,
  @location(1) b: vec3f,
) -> FlatOut {
  var end_of = array<u32, 6>(0, 0, 1, 1, 0, 1);
  var side_of = array<f32, 6>(-1, 1, -1, -1, 1, 1);
  let ca = g.view_proj * g.model * vec4f(a, 1.0);
  let cb = g.view_proj * g.model * vec4f(b, 1.0);
  let hs = g.screen.xy * 0.5;
  let sa = ca.xy / ca.w * hs;
  let sb = cb.xy / cb.w * hs;
  let d = normalize(sb - sa);
  let offset_px = vec2f(-d.y, d.x) * side_of[vi] * (g.screen.z * 0.5);
  var c = ca;
  if (end_of[vi] == 1u) { c = cb; }
  let ndc = c.xy / c.w + offset_px / hs;
  var o: FlatOut;
  o.pos = vec4f(ndc * c.w, (c.z / c.w - 0.0006) * c.w, c.w);
  o.color = vec3f(0.04, 0.04, 0.06);
  return o;
}
