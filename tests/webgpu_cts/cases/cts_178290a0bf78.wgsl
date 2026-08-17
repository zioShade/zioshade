
enable f16;
@compute @workgroup_size(1)
fn main() {
  const foo = mat3x2h(1,1,1,1,1,1,) * mat2x3h(1,1,1,1,1,1,);
}
