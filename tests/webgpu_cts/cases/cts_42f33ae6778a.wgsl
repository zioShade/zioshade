
@group(0) @binding(1) var t: texture_depth_multisampled_2d;
@fragment fn fs() -> @location(0) vec4f {
  let v = textureNumSamples(t);
  return vec4f(0);
}
