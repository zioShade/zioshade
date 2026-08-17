
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupAnd(i32(0));
}
