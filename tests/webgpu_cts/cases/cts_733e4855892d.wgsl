
enable f16;
@compute @workgroup_size(1)
fn main() {
  const foo = mat4x3h(1,1,1,1,1,1,1,1,1,1,1,1,) * vec4h(1);
}
