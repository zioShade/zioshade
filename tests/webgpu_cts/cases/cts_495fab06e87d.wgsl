
enable atomic_vec2u_min_max;
@group(0) @binding(0) var<storage, read_write> a : atomic<vec2u>;

@compute @workgroup_size(1,1,1) fn main() {
  atomicStoreMax(&a, vec2u(1, 1));
}
