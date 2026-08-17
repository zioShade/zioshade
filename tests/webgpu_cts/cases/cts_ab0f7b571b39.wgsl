
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  let res : i32 = subgroupOr(i32(0));
}
