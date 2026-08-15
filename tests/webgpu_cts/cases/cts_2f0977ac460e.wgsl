
@group(0) @binding(1) var t: texture_storage_2d_array<r32uint, read>;
@fragment fn fs() -> @location(0) vec4f {
  let v = textureNumLayers(t);
  return vec4f(0);
}
