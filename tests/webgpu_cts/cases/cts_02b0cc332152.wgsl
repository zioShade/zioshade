
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  let res : vec2<u32> = subgroupAnd(vec2(0u, 0u));
}
