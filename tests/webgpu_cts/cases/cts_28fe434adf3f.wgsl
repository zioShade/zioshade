
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupMax(i32(0));
}
