var<workgroup> x: i32;
@compute @workgroup_size(1)
fn main() {
  let p: ptr<workgroup,i32> = &x;
}
