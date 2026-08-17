
enable f16;
@compute @workgroup_size(1)
fn main() {
  const foo = mat3x2h(65504,65504,65504,65504,65504,65504,) * vec3h(1/3);
}
