
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = subgroupAnd(vec3(0, 0, 0));
}
