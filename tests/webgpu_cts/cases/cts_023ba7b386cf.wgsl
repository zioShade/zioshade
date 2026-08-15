
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupMin(i32(0));
}
