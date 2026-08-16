
enable atomic_vec2u_min_max;
@group(0) @binding(0) var<storage, read_write> a : atomic<vec2u>;

@fragment fn main() -> @location(0) vec4<f32> {
  atomicStoreMax(&a, vec2u(1, 1));
  return vec4<f32>();
}
