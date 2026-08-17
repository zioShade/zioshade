
enable f16;

@compute @workgroup_size(1)
fn main() {
  let foo = 1h * mat2x3h();
}
