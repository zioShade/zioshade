
enable subgroups;

@compute @workgroup_size(1)
fn main() {
  let res : vec4<i32> = quadSwapDiagonal(vec4(i32(0), i32(0), i32(0), i32(0)));
}
