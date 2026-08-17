
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  let res : vec4<f32> = quadSwapX(vec4(0.0, 0.0, 0.0, 0.0));
}
