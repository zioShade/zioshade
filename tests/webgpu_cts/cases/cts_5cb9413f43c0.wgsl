
enable f16;
@compute @workgroup_size(1)
fn main() {
  const foo = mat4x3h(65504,65504,65504,65504,65504,65504,65504,65504,65504,65504,65504,65504,) * vec4h(1/4);
}
