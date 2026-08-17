
@compute @workgroup_size(1)
fn main() {
  const foo = mat4x3(1,1,1,1,1,1,1,1,1,1,1,1,) * mat3x4(1,1,1,1,1,1,1,1,1,1,1,1,);
}
