
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupMin(vec2(i32(0), i32(0)));
}
