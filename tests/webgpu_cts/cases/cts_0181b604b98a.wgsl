
@compute @workgroup_size(1)
fn main() {
  const foo = mat4x2(1,1,1,1,1,1,1,1,) * vec4(1);
}
