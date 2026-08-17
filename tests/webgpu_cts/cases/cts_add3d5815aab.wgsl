
@compute @workgroup_size(1)
fn main() {
  const foo = mat2x4f(1,1,1,1,1,1,1,1,) * vec2f(1);
}
