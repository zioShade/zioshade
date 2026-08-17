
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupShuffleUp(vec4(0u, 0u, 0u, 0u), 0);
}
