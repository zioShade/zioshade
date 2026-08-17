var<private> x: i32;
@compute @workgroup_size(1)
fn main() {
  x = 0;
}
