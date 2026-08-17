
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = quadSwapY(i32(0));
}
