
enable f16;
@compute @workgroup_size(1)
fn main() {
  const foo = mat2x2h(32752,32752,32752,32752,) + mat2x2h(1,1,1,1,);
}
