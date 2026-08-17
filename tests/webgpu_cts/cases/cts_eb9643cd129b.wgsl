
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  let res : vec4<i32> = subgroupAnd(vec4(0, 0, 0, 0));
}
