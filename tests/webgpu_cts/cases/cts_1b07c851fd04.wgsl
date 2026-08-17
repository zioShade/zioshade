
enable subgroups;
@compute @workgroup_size(1)
fn main() {
  _ = subgroupBroadcast(0, i32(0));
}
