
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = quadSwapY(vec3(0.0, 0.0, 0.0));
}
