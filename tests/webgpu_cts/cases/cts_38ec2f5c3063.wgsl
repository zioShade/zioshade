@compute @workgroup_size(1)
fn main() {
  var x: i32;
let p: ptr<function,i32> = &x; let read = *p;
}
