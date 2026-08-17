
enable f16;
@compute @workgroup_size(1)
fn main() {
  const foo = mat2x2h(65504,65504,0,0,) * mat2x2h(1,1,0,0,);
}
