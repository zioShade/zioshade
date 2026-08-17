
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupShuffleDown(0.0, 0);
}
