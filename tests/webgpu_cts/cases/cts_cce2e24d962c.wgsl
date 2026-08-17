
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupXor(vec2(i32(0), i32(0)));
}
