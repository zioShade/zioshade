
@group(0) @binding(0) var s: sampler;
@group(0) @binding(1) var t: texture_depth_2d;
@fragment fn fs() -> @location(0) vec4f {
  let v = textureSample(t, s, vec2(0.0f, 0.0f));
  return vec4f(0);
}
