
enable f16;
@compute @workgroup_size(1)
fn main() {
  const foo = mat2x2h(1,1,1,1,) * vec2h(1);
}
