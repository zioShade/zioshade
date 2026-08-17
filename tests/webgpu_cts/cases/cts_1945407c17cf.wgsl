
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = quadSwapDiagonal(i32(0));
}
