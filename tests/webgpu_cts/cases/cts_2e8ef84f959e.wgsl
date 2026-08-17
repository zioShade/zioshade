
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  let res : vec3<f32> = subgroupBroadcastFirst(vec3(0.0f, 0.0f, 0.0f));
}
