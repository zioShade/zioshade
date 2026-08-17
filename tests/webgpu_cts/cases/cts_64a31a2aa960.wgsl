
@compute @workgroup_size(1)
fn main() {
  const foo = mat2x4f(1,1,1,1,1,1,1,1,) * mat4x2f(1,1,1,1,1,1,1,1,);
}
