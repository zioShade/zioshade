
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  let res : vec3<u32> = subgroupBroadcastFirst(vec3(0u, 0u, 0u));
}
