
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  let res : vec2<f32> = subgroupShuffleXor(vec2(0.0, 0.0), 0);
}
