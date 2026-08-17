
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupBroadcast(vec3(i32(0), i32(0), i32(0)), 0);
}
