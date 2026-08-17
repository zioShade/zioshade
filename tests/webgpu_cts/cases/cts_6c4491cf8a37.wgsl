
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = quadSwapDiagonal(vec3(0.0f, 0.0f, 0.0f));
}
