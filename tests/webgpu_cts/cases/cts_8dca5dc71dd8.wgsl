
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = quadSwapY(vec2(0u, 0u));
}
