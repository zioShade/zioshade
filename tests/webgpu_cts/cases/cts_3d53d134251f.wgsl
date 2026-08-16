
@group(0) @binding(0) var s: sampler;
@group(0) @binding(1) var t: texture_2d_array<u32>;
@fragment fn fs() -> @location(0) vec4f {
  let v = textureGather(0, t, s, vec2(0.0f, 0.0f), 0, vec2(i32(0), i32(0)));
  return vec4f(0);
}
