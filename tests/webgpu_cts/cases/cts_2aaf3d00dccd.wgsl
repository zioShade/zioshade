
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupShuffleUp(0.0f, 0);
}
