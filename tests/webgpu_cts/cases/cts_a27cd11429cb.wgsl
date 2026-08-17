
@compute @workgroup_size(1)
fn main() {
  const foo = mat4x2f(1,1,1,1,1,1,1,1,) * vec4f(1);
}
