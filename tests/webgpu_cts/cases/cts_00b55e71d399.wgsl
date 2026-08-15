
@compute @workgroup_size(1)
fn main() {
  const foo = mat4x3f(3.4028234663852886e+38,3.4028234663852886e+38,3.4028234663852886e+38,0,0,0,0,0,0,0,0,0,) * vec4f(1);
}
