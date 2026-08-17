
enable subgroups;
fn foo() {
  _ = quadSwapDiagonal(0);
}


@compute @workgroup_size(1)
fn main() {
  foo();
}
