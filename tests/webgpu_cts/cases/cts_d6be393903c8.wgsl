
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  let res : vec3<f32> = subgroupMin(vec3(0.0, 0.0, 0.0));
}
