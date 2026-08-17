
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupShuffleXor(0, 0u);
}
