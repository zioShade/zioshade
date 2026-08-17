
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  let res : vec2<i32> = quadSwapY(vec2(i32(0), i32(0)));
}
