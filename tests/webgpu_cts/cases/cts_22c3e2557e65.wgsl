
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupBroadcastFirst(vec4(0.0, 0.0, 0.0, 0.0));
}
