
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupBroadcast(i32(0), 0);
}
