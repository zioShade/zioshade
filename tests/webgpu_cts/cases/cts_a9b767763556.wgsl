
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  let res : vec3<i32> = subgroupMin(vec3(i32(0), i32(0), i32(0)));
}
