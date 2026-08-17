
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupOr(i32(0));
}
