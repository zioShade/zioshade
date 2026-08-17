
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = quadSwapY(0.0);
}
