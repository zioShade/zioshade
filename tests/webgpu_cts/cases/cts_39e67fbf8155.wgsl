
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  let res : f32 = subgroupBroadcastFirst(0.0f);
}
