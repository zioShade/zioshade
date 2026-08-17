
@group(0) @binding(0) var<storage, read_write> a: atomic<i32>;

@fragment fn main() -> @location(0) vec4<f32> {
  atomicStore(&a,1);
  return vec4<f32>();
}
