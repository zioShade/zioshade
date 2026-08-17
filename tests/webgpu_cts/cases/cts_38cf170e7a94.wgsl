
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupXor(vec3(0, 0, 0));
}
