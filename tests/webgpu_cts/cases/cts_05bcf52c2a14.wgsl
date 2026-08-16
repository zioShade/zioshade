
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  let res : vec4<f32> = quadBroadcast(vec4(0.0f, 0.0f, 0.0f, 0.0f), 0);
}
