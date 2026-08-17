
@group(0) @binding(1) var t: texture_cube<u32>;
@fragment fn fs() -> @location(0) vec4f {
  let v = textureNumLevels(t);
  return vec4f(0);
}
