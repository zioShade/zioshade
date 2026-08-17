
@compute @workgroup_size(1)
fn main() {
  const foo = mat3x2f(3.4028234663852886e+38,3.4028234663852886e+38,0,0,0,0,) * vec3f(1);
}
