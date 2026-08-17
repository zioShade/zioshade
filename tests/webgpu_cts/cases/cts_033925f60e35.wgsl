
@compute @workgroup_size(1)
fn main() {
  const foo = mat3x2f(1,1,1,1,1,1,) * mat2x3f(1,1,1,1,1,1,);
}
