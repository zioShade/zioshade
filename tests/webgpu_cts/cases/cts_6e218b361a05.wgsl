
@group(0) @binding(0) var s: sampler;
@group(0) @binding(1) var t: texture_external;
@fragment fn fs() -> @location(0) vec4f {
  let v = textureSampleBaseClampToEdge(t, s, vec2f(0));
  return vec4f(0);
}
