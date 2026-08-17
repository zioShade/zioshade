
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  let res : vec2<i32> = quadSwapX(vec2(0, 0));
}
