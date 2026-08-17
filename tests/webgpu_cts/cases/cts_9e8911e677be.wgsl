
enable f16;
@compute @workgroup_size(1)
fn main() {
  const foo = mat3x3h(65504,65504,65504,0,0,0,0,0,0,) * mat3x3h(1,1,1,0,0,0,0,0,0,);
}
