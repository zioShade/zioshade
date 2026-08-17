
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  let res : i32 = subgroupShuffleXor(i32(0), 0);
}
