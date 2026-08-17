
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  let res : vec3<i32> = subgroupOr(vec3(0, 0, 0));
}
