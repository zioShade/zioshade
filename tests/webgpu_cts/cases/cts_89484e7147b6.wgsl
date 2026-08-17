
enable f16;
@compute @workgroup_size(1)
fn main() {
  const foo = mat3x4h(65504,65504,65504,65504,0,0,0,0,0,0,0,0,) * 1;
}
