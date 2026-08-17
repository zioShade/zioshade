
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = quadSwapX(vec4(0, 0, 0, 0));
}
