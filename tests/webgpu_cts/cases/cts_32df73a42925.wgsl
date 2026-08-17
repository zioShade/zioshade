
enable subgroups;
@compute @workgroup_size(16)
fn main() {
  let x = subgroupShuffleUp(0, 0);
}
