
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupShuffle(vec4(i32(0), i32(0), i32(0), i32(0)), 0);
}
