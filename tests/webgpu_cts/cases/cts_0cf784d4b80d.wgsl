
enable f16;
@compute @workgroup_size(1)
fn main() {
  const foo = mat4x4h(65504,65504,65504,65504,0,0,0,0,0,0,0,0,0,0,0,0,) * mat4x4h(1,1,1,1,0,0,0,0,0,0,0,0,0,0,0,0,);
}
