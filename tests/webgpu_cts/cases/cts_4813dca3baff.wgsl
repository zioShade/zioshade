@compute @workgroup_size(1)
fn main() {
  var x: i32;
let p = &x; *p = 42;
}
