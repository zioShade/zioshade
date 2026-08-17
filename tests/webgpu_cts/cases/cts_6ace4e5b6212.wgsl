
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupXor(vec3(0u, 0u, 0u));
}
