
@compute @workgroup_size(1)
fn main() {
  const foo = mat3x3f(1,1,1,1,1,1,1,1,1,) * vec3f(1);
}
