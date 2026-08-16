
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  let res : i32 = subgroupShuffleUp(i32(0), 0);
}
