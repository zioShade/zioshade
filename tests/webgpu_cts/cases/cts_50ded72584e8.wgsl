
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  _ = quadSwapY(vec3(i32(0), i32(0), i32(0)));
}
