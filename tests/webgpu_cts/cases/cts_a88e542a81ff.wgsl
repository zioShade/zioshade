
@group(0) @binding(0) var s: sampler;
@group(0) @binding(1) var t: texture_3d<f32>;
@group(0) @binding(2) var<uniform> u: vec3<i32>;
@fragment fn fs() -> @location(0) vec4f {
  const c = 1;
  let l = vec3(i32(0), i32(0), i32(0));
  let v = textureSampleBias(t, s, vec3(0.0f, 0.0f, 0.0f), 0, vec3<i32>(c));
  return vec4f(0);
}
