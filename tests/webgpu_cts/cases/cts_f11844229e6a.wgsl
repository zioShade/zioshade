
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupMin(vec3(0, 0, 0));
}
