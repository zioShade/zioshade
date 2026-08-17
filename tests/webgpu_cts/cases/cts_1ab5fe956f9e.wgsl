
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  let res : vec4<u32> = subgroupShuffleDown(vec4(0u, 0u, 0u, 0u), 0);
}
