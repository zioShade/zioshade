
enable subgroups;
enable f16;
@compute @workgroup_size(1)
fn main() {
  let res : vec3<f16> = quadSwapY(vec3(0.0h, 0.0h, 0.0h));
}
