
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = quadSwapDiagonal(0.0f);
}
