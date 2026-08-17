
@group(0) @binding(0) var s: sampler_comparison;
@group(0) @binding(1) var t: texture_depth_cube_array;
@fragment fn fs() -> @location(0) vec4f {
  let v = textureGatherCompare(t, s, vec3(0.0f, 0.0f, 0.0f), 0, 0);
  return vec4f(0);
}
