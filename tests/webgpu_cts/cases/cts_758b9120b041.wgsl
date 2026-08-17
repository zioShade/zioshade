
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupShuffleDown(vec3(i32(0), i32(0), i32(0)), 0);
}
