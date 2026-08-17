
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  let res : vec2<f32> = subgroupMax(vec2(0.0, 0.0));
}
