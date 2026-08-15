
@group(0) @binding(0) var s: sampler_comparison;
@group(0) @binding(1) var t: texture_depth_2d;
@fragment fn fs() -> @location(0) vec4f {
  let v = textureGatherCompare(t, s, vec2(0.0f, 0.0f), 0, vec2(i32(0), i32(0)));
  return vec4f(0);
}
