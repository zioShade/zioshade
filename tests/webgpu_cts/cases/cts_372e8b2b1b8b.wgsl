
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  let res : vec4<u32> = subgroupShuffleUp(vec4(0u, 0u, 0u, 0u), 0);
}
