
@compute @workgroup_size(1)
fn main() {
  const foo = mat2x3(1,1,1,1,1,1,) * vec2(1);
}
