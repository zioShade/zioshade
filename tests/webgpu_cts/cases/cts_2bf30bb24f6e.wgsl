
enable f16;
@compute @workgroup_size(1)
fn main() {
  const foo = mat4x2h(1,1,1,1,1,1,1,1,) * mat2x4h(1,1,1,1,1,1,1,1,);
}
