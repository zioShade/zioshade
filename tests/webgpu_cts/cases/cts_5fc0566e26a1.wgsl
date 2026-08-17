
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupShuffleDown(i32(0), 0);
}
