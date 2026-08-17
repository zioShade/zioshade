
@compute @workgroup_size(1)
fn main() {
  const foo = mat2x2(1.7976931348623157e+308,1.7976931348623157e+308,0,0,) * vec2(1);
}
