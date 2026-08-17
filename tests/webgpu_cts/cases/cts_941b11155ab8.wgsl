
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupBroadcastFirst(vec2(0.0f, 0.0f));
}
