
@compute @workgroup_size(1)
fn main() {
  const foo = mat3x3(1,1,1,1,1,1,1,1,1,) * vec3(1);
}
