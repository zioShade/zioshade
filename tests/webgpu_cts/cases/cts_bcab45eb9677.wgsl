@compute @workgroup_size(1)
fn main() {
  var<function> x: i32;
let p = &x; let read = *p;
}
