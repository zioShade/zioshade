
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  let res : vec3<f32> = subgroupShuffleUp(vec3(0.0, 0.0, 0.0), 0);
}
