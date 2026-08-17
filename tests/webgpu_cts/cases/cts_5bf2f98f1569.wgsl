
@compute @workgroup_size(1)
fn main() {
  const foo = mat2x2f(1,1,1,1,) * mat2x2f(1,1,1,1,);
}
