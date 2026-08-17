
@compute @workgroup_size(1)
fn main() {
  const foo = mat4x2(1,1,1,1,1,1,1,1,) * mat2x4(1,1,1,1,1,1,1,1,);
}
