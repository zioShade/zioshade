
enable subgroups;
enable f16;
@compute @workgroup_size(1)
fn main() {
  _ = quadSwapX(vec4(0.0h, 0.0h, 0.0h, 0.0h));
}
